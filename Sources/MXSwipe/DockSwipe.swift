import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Synchronization
import SystemEvents

/// Panel motion waiting to reach the Dock. Reports that arrive while a post is running are summed, so a
/// slow post delays the desktop by one event rather than by a growing queue of stale ones.
final class PanelMotionBuffer: Sendable {
    private struct State {
        var total = 0
        var latest = 0
        var drainScheduled = false
    }

    private let state = Mutex(State())

    /// Returns true when the caller must schedule a `take()`; one is otherwise already on its way.
    func add(_ delta: Int) -> Bool {
        state.withLock {
            $0.total += delta
            $0.latest = delta
            guard !$0.drainScheduled else { return false }
            $0.drainScheduled = true
            return true
        }
    }

    func take() -> (total: Int, latest: Int) {
        state.withLock {
            defer { $0 = State() }
            return ($0.total, $0.latest)
        }
    }
}

/// Drives the Dock's Space and Mission Control transitions from panel gestures, the way a trackpad does:
/// the desktop follows the finger, then commits or springs back on release. When the private DockSwipe
/// event is unavailable, a released swipe becomes the equivalent Control-arrow shortcut instead.
///
/// Confined to the session's output queue.
final class DockSwipeController: @unchecked Sendable {
    struct Swipe: Equatable {
        enum Phase: Int { case began = 1, changed = 2, ended = 4, cancelled = 8 }

        let axis: GestureAxis
        let progress: Double
        let phase: Phase
        /// Set on ended and cancelled; the Dock uses it to finish the animation at the finger's speed.
        var exitSpeed = 0.0
        /// Frozen when the swipe begins, so changing the setting mid-swipe can't reverse it.
        var naturalScrolling = true
    }

    /// Progress per raw panel unit; 1.0 is one complete transition, about 420 units of travel.
    static let progressPerUnit = 1.2 / 500

    private let post: (Swipe) -> Bool
    private let postControlArrow: (Int) -> Bool
    private let naturalScrolling: () -> Bool
    private let spaceKeeper: FullScreenSpaceKeeper?

    private var axis: GestureAxis?
    private var progress = 0.0
    /// The most recent progress change. Its sign tells a release while reversing from a release while
    /// still moving forward, and it sets the exit speed.
    private var lastDelta = 0.0
    private var naturalScrollingAtBegin = true
    private var usesKeyboardFallback = false

    init(
        post: @escaping (Swipe) -> Bool = DockSwipeController.post,
        postControlArrow: @escaping (Int) -> Bool = { MXPostControlArrow(CGKeyCode($0)) },
        naturalScrolling: @escaping () -> Bool = isNaturalScrollingEnabled,
        spaceKeeper: FullScreenSpaceKeeper? = nil
    ) {
        self.post = post
        self.postControlArrow = postControlArrow
        self.naturalScrolling = naturalScrolling
        self.spaceKeeper = spaceKeeper
    }

    func handle(_ event: PanelGestureEvent) {
        switch event {
        case let .began(axis, delta):
            cancel()
            if axis == .vertical { spaceKeeper?.prepare() }
            self.axis = axis
            progress = Self.progress(for: delta, axis: axis)
            lastDelta = progress
            naturalScrollingAtBegin = naturalScrolling()
            usesKeyboardFallback = !post(swipe(.began))

        case let .changed(delta):
            move(by: delta, latest: delta)

        case .ended:
            guard let axis else { return }
            if usesKeyboardFallback {
                _ = postControlArrow(fallbackKey(for: axis))
            } else {
                // Releasing at the origin, or while moving back toward it, springs back.
                let reversing = progress != 0 && (progress < 0) != (lastDelta < 0)
                _ = post(swipe(progress == 0 || reversing ? .cancelled : .ended))
            }
            reset()

        case .cancelled:
            cancel()
        }
    }

    /// Applies motion summed from reports ending in `latest`, which alone sets the direction and exit
    /// speed: the sum says how far the panel moved, not how fast or which way it was last going.
    func move(by delta: Int, latest: Int) {
        guard let axis, latest != 0 else { return }
        lastDelta = Self.progress(for: latest, axis: axis)
        guard delta != 0 else { return }
        progress += Self.progress(for: delta, axis: axis)
        if !usesKeyboardFallback { _ = post(swipe(.changed)) }
    }

    /// A tap on the panel: Mission Control, immediately.
    func tap() {
        spaceKeeper?.prepare()
        _ = postControlArrow(kVK_UpArrow)
        spaceKeeper?.settle()
    }

    /// Closes an unfinished swipe so the Dock doesn't stay mid-transition.
    func cancel() {
        guard axis != nil else { return }
        if !usesKeyboardFallback { _ = post(swipe(.cancelled)) }
        reset()
    }

    private func swipe(_ phase: Swipe.Phase) -> Swipe {
        let ending = phase == .ended || phase == .cancelled
        return Swipe(axis: axis!, progress: progress, phase: phase,
                     exitSpeed: ending ? lastDelta * 100 : 0, naturalScrolling: naturalScrollingAtBegin)
    }

    private func reset() {
        axis = nil
        progress = 0
        lastDelta = 0
        usesKeyboardFallback = false
        spaceKeeper?.settle()
    }

    /// Horizontal motion is reversed so the desktop tracks the finger: moving left reveals the next
    /// Space. Raw XY already reports upward motion as negative, which the Dock reads as Mission Control.
    private static func progress(for rawDelta: Int, axis: GestureAxis) -> Double {
        Double(axis == .horizontal ? -rawDelta : rawDelta) * progressPerUnit
    }

    /// Control-Right shows the next Space, Control-Left the previous, Control-Up toggles Mission Control.
    private func fallbackKey(for axis: GestureAxis) -> Int {
        guard axis == .horizontal else { return kVK_UpArrow }
        let towardNext = progress != 0 ? progress > 0 : lastDelta > 0
        return towardNext ? kVK_RightArrow : kVK_LeftArrow
    }
}

// MARK: Posting

extension DockSwipeController {
    /// Posts a swipe to the Dock. Returns false when this macOS has no validated event layout for it.
    static func post(_ swipe: Swipe) -> Bool {
        // The event layouts are private and change between major releases; each needs revalidating.
        if #available(macOS 28, *) { return false }
        guard CGPreflightPostEventAccess() else { return false }
        if #available(macOS 27, *) {
            guard let event = MXCreateHIDDockSwipeEvent(swipe.progress, swipe.axis.rawValue, swipe.phase.rawValue,
                                                        swipe.exitSpeed, swipe.naturalScrolling) else { return false }
            event.post(tap: .cgSessionEventTap)
            return true
        }
        guard let (dock, gesture) = legacyEvents(for: swipe) else { return false }
        dock.post(tap: .cgSessionEventTap)
        gesture.post(tap: .cgSessionEventTap)
        return true
    }

    /// The macOS 26 DockSwipe: a pair of CGEvents with private fields. Verified against the active Space
    /// on 25F84; the field layout was informed by Mac Mouse Fix's published reverse engineering.
    static func legacyEvents(for swipe: Swipe) -> (dock: CGEvent, gesture: CGEvent)? {
        guard let dock = CGEvent(source: nil), let gesture = CGEvent(source: nil) else { return nil }
        func set(_ event: CGEvent, _ field: UInt32, _ value: Double) {
            event.setDoubleValueField(CGEventField(rawValue: field)!, value: value)
        }
        let phase = Double(swipe.phase.rawValue)
        let axis = Double(swipe.axis.rawValue)
        // The axis enum's bits read back through a Float field: 1.4e-45 for horizontal, 2.8e-45 for vertical.
        let encodedAxis = Double(Float(bitPattern: UInt32(swipe.axis.rawValue)))

        set(gesture, 55, 29) // NSEventTypeGesture
        set(gesture, 41, 33231)
        set(dock, 55, 30) // NSEventTypeMagnify
        set(dock, 110, 23) // kIOHIDEventTypeDockSwipe
        set(dock, 41, 33231)
        set(dock, 132, phase)
        set(dock, 134, phase)
        set(dock, 124, swipe.progress)
        dock.setIntegerValueField(CGEventField(rawValue: 135)!, value: Int64(Float(swipe.progress).bitPattern))
        set(dock, 119, encodedAxis)
        set(dock, 139, encodedAxis)
        set(dock, 123, axis)
        set(dock, 165, axis)
        dock.setIntegerValueField(CGEventField(rawValue: 136)!, value: 1)
        if swipe.phase == .ended || swipe.phase == .cancelled {
            set(dock, 129, swipe.exitSpeed)
            set(dock, 130, swipe.exitSpeed)
        }
        return (dock, gesture)
    }

    /// Whether the Dock is showing Mission Control, from its Accessibility tree.
    static func isMissionControlOpen() -> Bool {
        missionControlState() ?? false
    }

    /// As `isMissionControlOpen`, or nil when the Dock can't be read.
    static func missionControlState() -> Bool? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(dock.processIdentifier),
                                            kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement] else { return nil }
        return elements.contains { element in
            var identifier: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &identifier) == .success
                && identifier as? String == "mc"
        }
    }
}

/// The system's scroll-direction setting. Unset means natural scrolling, the macOS default.
func isNaturalScrollingEnabled() -> Bool {
    UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
}
