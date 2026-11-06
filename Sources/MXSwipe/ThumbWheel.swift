import CoreGraphics
import Foundation
import Synchronization

/// A rotation or touch report from the HID++ thumb wheel feature (0x2150), once it is diverted.
struct ThumbWheelReport: Equatable {
    enum State: UInt8 { case inactive = 0, began = 1, changed = 2, ended = 3 }

    let delta: Int
    let state: State

    init?(packet: HIDPPPacket, deviceIndex: UInt8, featureIndex: UInt8) {
        guard packet.deviceIndex == deviceIndex, packet.featureIndex == featureIndex,
              packet.softwareID == 0, packet.function == 0, packet.parameters.count >= 6,
              let state = State(rawValue: packet.parameters[4]) else { return nil }
        delta = signed16(packet.parameters[0], packet.parameters[1])
        self.state = state
    }
}

/// Turns thumb wheel rotation into the phased, pixel-precise horizontal scroll gesture a trackpad
/// produces, so apps can scroll content or swipe between pages as they would with two fingers.
///
/// Each wheel step is spread over a few 120 Hz frames. Confined to the session queue, which also runs
/// its frame timer.
final class ThumbWheelScrollController: @unchecked Sendable {
    enum Phase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 }

    /// Set from the device's reported resolution and direction when the wheel is configured.
    var pixelsPerUnit = 10.0
    var deviceDirection = 1.0
    private(set) var isActive = false

    private let queue: DispatchQueue?
    private let postQueue: DispatchQueue?
    private let smoothingFrames: Int
    private let post: (CGEvent) -> Void
    private let naturalScrolling: () -> Bool
    private let pointerLocation: () -> CGPoint
    private let eventSource = makeEventSource()
    private var timer: DispatchSourceTimer?
    private let postsInFlight = Atomic<Int>(0)
    private var pendingFrames: [Double] = []
    private var pixelRemainder = 0.0
    private var ending = false
    private var beganPosted = false
    private var direction = 1.0

    /// Without a queue there is no frame timer; tests drive frames with `advanceFrame()`. Events are
    /// posted on `postQueue` when there is one, so a stalled post can't hold up `queue`.
    init(
        queue: DispatchQueue? = nil,
        postQueue: DispatchQueue? = nil,
        smoothingFrames: Int = 4,
        pointerLocation: @escaping () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero },
        naturalScrolling: @escaping () -> Bool = isNaturalScrollingEnabled,
        post: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }
    ) {
        precondition(smoothingFrames > 0)
        self.queue = queue
        self.postQueue = postQueue
        self.smoothingFrames = smoothingFrames
        self.pointerLocation = pointerLocation
        self.naturalScrolling = naturalScrolling
        self.post = post
    }

    func consume(_ report: ThumbWheelReport) {
        if report.state == .began, isActive {
            flushPendingFrames()
            finish()
        }
        if report.delta != 0 {
            ending = false
            if !isActive {
                isActive = true
                // Positive horizontal CG deltas move the viewport left. Normalize the firmware's
                // direction, then freeze the scroll preference for the rest of the gesture.
                direction = -deviceDirection * (naturalScrolling() ? -1 : 1)
            }
            let delta = Double(report.delta) * pixelsPerUnit * direction
            // A reversal takes effect now rather than after the buffered motion drains.
            if pendingFrames.reduce(0, +) * delta < 0 { flushPendingFrames() }
            let exactPixels = delta + pixelRemainder
            let pixels = exactPixels.rounded()
            pixelRemainder = exactPixels - pixels
            while pendingFrames.count < smoothingFrames { pendingFrames.append(0) }
            // Whole-pixel slices that sum to the total, so slow turns aren't rounded away frame by frame.
            for index in 0 ..< smoothingFrames {
                pendingFrames[index] += (pixels * Double(index + 1) / Double(smoothingFrames)).rounded()
                    - (pixels * Double(index) / Double(smoothingFrames)).rounded()
            }
            // Move at once when no frame is due; otherwise a slow turn waits a frame on every step.
            if !beganPosted || (queue != nil && timer == nil) { advanceFrame() }
            startTimerIfNeeded()
        }
        if report.state == .ended || report.state == .inactive { finish() }
    }

    /// Ends the gesture once buffered frames have drained, or immediately when cancelling.
    func finish(cancelled: Bool = false) {
        guard isActive else { return }
        if !cancelled, !pendingFrames.isEmpty {
            ending = true
            return
        }
        if beganPosted { send(delta: 0, phase: cancelled ? .cancelled : .ended) }
        timer?.cancel()
        timer = nil
        pendingFrames.removeAll()
        isActive = false
        beganPosted = false
        ending = false
        pixelRemainder = 0
    }

    func advanceFrame() {
        if !pendingFrames.isEmpty {
            let delta = pendingFrames.removeFirst()
            if delta != 0 {
                send(delta: delta, phase: beganPosted ? .changed : .began)
                beganPosted = true
            }
        }
        if pendingFrames.isEmpty {
            timer?.cancel()
            timer = nil
            if ending { finish() }
        }
    }

    /// Skips the frame while a post is still running. Its pixels stay in the fixed-size pending frames,
    /// so a stalled post slows the scroll instead of building a queue of stale events.
    private func frameTimerFired() {
        if postsInFlight.load(ordering: .relaxed) == 0 { advanceFrame() }
    }

    private func flushPendingFrames() {
        while !pendingFrames.isEmpty { advanceFrame() }
    }

    private func startTimerIfNeeded() {
        guard timer == nil, !pendingFrames.isEmpty, let queue else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0 / 120, repeating: 1.0 / 120, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.frameTimerFired() }
        self.timer = timer
        timer.resume()
    }

    private func send(delta: Double, phase: Phase) {
        guard let event = Self.makeEvent(delta: delta, phase: phase, source: eventSource) else { return }
        guard let postQueue else { return stampAndPost(event) }
        nonisolated(unsafe) let unsentEvent = event
        postsInFlight.add(1, ordering: .relaxed)
        postQueue.async { [self] in
            stampAndPost(unsentEvent)
            postsInFlight.subtract(1, ordering: .relaxed)
        }
    }

    private func stampAndPost(_ event: CGEvent) {
        // Sample the pointer and modifiers for every frame, including the final one, so the scroll lands
        // where the pointer is now rather than where the gesture started.
        event.location = pointerLocation()
        event.flags = CGEvent(source: nil)?.flags ?? []
        post(event)
    }

    /// A private source whose events don't suppress the user's own mouse and keyboard input.
    static func makeEventSource() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        source.localEventsSuppressionInterval = 0
        let allowed: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source.setLocalEventsFilterDuringSuppressionState(allowed, state: .eventSuppressionStateSuppressionInterval)
        source.setLocalEventsFilterDuringSuppressionState(allowed, state: .eventSuppressionStateRemoteMouseDrag)
        return source
    }

    static func makeEvent(delta: Double, phase: Phase, source: CGEventSource? = nil) -> CGEvent? {
        guard let source = source ?? makeEventSource(),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: 0, wheel2: Int32(delta.rounded()), wheel3: 0) else { return nil }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // The line delta keeps the initializer's fixed-point value; precise consumers read this one.
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: delta)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        return event
    }
}
