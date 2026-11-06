import AppKit
import XCTest
@testable import MXSwipe

final class ThumbWheelScrollControllerTests: XCTestCase {
    func testEventsArePreciseHorizontalAppKitScrollGestures() throws {
        for (phase, expected) in [
            (ThumbWheelScrollController.Phase.began, NSEvent.Phase.began),
            (.changed, .changed), (.ended, .ended), (.cancelled, .cancelled),
        ] {
            let delta = phase == .began || phase == .changed ? 12.0 : 0
            let cg = try XCTUnwrap(ThumbWheelScrollController.makeEvent(delta: delta, phase: phase))
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            XCTAssertEqual(event.type, .scrollWheel)
            XCTAssertTrue(event.hasPreciseScrollingDeltas)
            XCTAssertEqual(event.scrollingDeltaX, delta, accuracy: 0.001)
            XCTAssertEqual(event.scrollingDeltaY, 0)
            XCTAssertEqual(event.phase, expected)
            XCTAssertEqual(event.momentumPhase, [])
        }
    }

    func testPointerMovementIsResampledThroughoutBufferedScrollAndRelease() throws {
        var pointer = CGPoint(x: 100, y: 100)
        var locations: [CGPoint] = []
        let controller = ThumbWheelScrollController(pointerLocation: { pointer }, post: {
            locations.append($0.location)
        })
        controller.consume(try report(delta: 4, state: 1))
        controller.consume(try report(delta: 0, state: 3))
        for index in 1 ... 3 {
            pointer = CGPoint(x: 100 + index * 50, y: 100 + index * 20)
            controller.advanceFrame()
        }
        XCTAssertEqual(locations, [CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 120),
                                   CGPoint(x: 200, y: 140), CGPoint(x: 250, y: 160),
                                   CGPoint(x: 250, y: 160)])
        XCTAssertFalse(controller.isActive)

        controller.consume(try report(delta: 4, state: 1))
        pointer = CGPoint(x: 600, y: 500)
        controller.finish(cancelled: true)
        XCTAssertEqual(locations.last, pointer)
    }

    func testScrollSourcePermitsPhysicalInputDuringPostingAndDragging() throws {
        let source = try XCTUnwrap(ThumbWheelScrollController.makeEventSource())
        XCTAssertEqual(source.localEventsSuppressionInterval, 0)
        for state in [CGEventSuppressionState.eventSuppressionStateSuppressionInterval,
                      .eventSuppressionStateRemoteMouseDrag] {
            let mask = source.getLocalEventsFilterDuringSuppressionState(state)
            XCTAssertTrue(mask.contains(.permitLocalMouseEvents))
            XCTAssertTrue(mask.contains(.permitLocalKeyboardEvents))
            XCTAssertTrue(mask.contains(.permitSystemDefinedEvents))
        }
    }

    func testLegacyLineDeltasRetainCoreGraphicsPixelConversion() throws {
        for pixels: Int32 in [-120, -12, 0, 12, 120] {
            let baseline = try XCTUnwrap(CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: 0, wheel2: pixels, wheel3: 0
            ))
            let generated = try XCTUnwrap(ThumbWheelScrollController.makeEvent(
                delta: Double(pixels), phase: .changed
            ))
            let expected = try XCTUnwrap(NSEvent(cgEvent: baseline))
            let actual = try XCTUnwrap(NSEvent(cgEvent: generated))
            XCTAssertEqual(actual.scrollingDeltaX, CGFloat(pixels), accuracy: 0.001)
            XCTAssertEqual(actual.deltaX, expected.deltaX, accuracy: 0.0001)
        }
    }

    @MainActor
    func testRightwardWheelMotionMovesViewportAccordingToNaturalScrolling() throws {
        _ = NSApplication.shared
        for natural in [false, true] {
            for deviceDirection in [-1.0, 1.0] {
                let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
                let window = NSWindow(contentRect: scrollView.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false)
                window.contentView = scrollView
                scrollView.hasHorizontalScroller = true
                scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1500, height: 300))
                scrollView.contentView.scroll(to: NSPoint(x: 500, y: 0))
                let controller = ThumbWheelScrollController(smoothingFrames: 1,
                                                           naturalScrolling: { natural }) {
                    scrollView.scrollWheel(with: NSEvent(cgEvent: $0)!)
                }
                controller.deviceDirection = deviceDirection
                // Both firmware conventions represent the same physical rightward roll.
                controller.consume(try report(delta: Int16(2 * deviceDirection), state: 1))
                controller.consume(try report(delta: Int16(2 * deviceDirection), state: 2))
                controller.advanceFrame()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                if natural {
                    XCTAssertLessThan(scrollView.contentView.bounds.origin.x, 500)
                } else {
                    XCTAssertGreaterThan(scrollView.contentView.bounds.origin.x, 500)
                }
                controller.finish()
                withExtendedLifetime(window) {}
            }
        }
    }

    func testRotationReversesWithinOneGestureAndReleaseEndsIt() throws {
        var events: [NSEvent] = []
        let controller = ThumbWheelScrollController(smoothingFrames: 1, naturalScrolling: { false }) {
            events.append(NSEvent(cgEvent: $0)!)
        }
        controller.consume(try report(delta: 2, state: 1))
        controller.consume(try report(delta: -1, state: 2))
        controller.advanceFrame()
        controller.consume(try report(delta: 0, state: 3))
        XCTAssertEqual(events.map(\.phase), [.began, .changed, .ended])
        XCTAssertEqual(events.map(\.scrollingDeltaX), [-20, 10, 0])
        XCTAssertFalse(controller.isActive)
    }

    func testSmoothingPreservesDistanceAndEndsAfterLastFrame() throws {
        var events: [NSEvent] = []
        let controller = ThumbWheelScrollController(naturalScrolling: { false }) {
            events.append(NSEvent(cgEvent: $0)!)
        }
        controller.consume(try report(delta: 1, state: 1))
        controller.consume(try report(delta: 0, state: 3))
        XCTAssertTrue(controller.isActive)
        XCTAssertLessThan(abs(events[0].scrollingDeltaX), 10)
        for _ in 0 ..< 4 { controller.advanceFrame() }
        XCTAssertEqual(events.map(\.scrollingDeltaX).reduce(0, +), -10)
        XCTAssertEqual(events.first?.phase, .began)
        XCTAssertEqual(events.last?.phase, .ended)
        XCTAssertFalse(controller.isActive)
    }

    func testSmoothedReversalPreservesDistanceWithoutOldDirectionTail() throws {
        var events: [NSEvent] = []
        let controller = ThumbWheelScrollController(naturalScrolling: { false }) {
            events.append(NSEvent(cgEvent: $0)!)
        }
        controller.consume(try report(delta: 4, state: 1))
        controller.consume(try report(delta: -2, state: 2))
        let reversalIndex = events.count
        controller.consume(try report(delta: 0, state: 3))
        for _ in 0 ..< 4 { controller.advanceFrame() }
        XCTAssertEqual(events.map(\.scrollingDeltaX).reduce(0, +), -20)
        XCTAssertTrue(events.dropFirst(reversalIndex).allSatisfy { $0.scrollingDeltaX >= 0 })
        XCTAssertEqual(events.filter { $0.phase == .began }.count, 1)
        XCTAssertEqual(events.last?.phase, .ended)
    }

    func testCancellationDiscardsBufferedMotion() throws {
        var events: [NSEvent] = []
        let controller = ThumbWheelScrollController(post: {
            events.append(NSEvent(cgEvent: $0)!)
        })
        controller.consume(try report(delta: 10, state: 1))
        controller.finish(cancelled: true)
        for _ in 0 ..< 8 { controller.advanceFrame() }
        XCTAssertEqual(events.map(\.phase), [.began, .cancelled])
    }

    func testTouchOnlyReportsDoNotStartScrolling() throws {
        var count = 0
        let controller = ThumbWheelScrollController(smoothingFrames: 1, post: { _ in count += 1 })
        for state: UInt8 in [0, 1, 2, 3] {
            controller.consume(try report(delta: 0, state: state))
        }
        XCTAssertEqual(count, 0)
    }

    func testLostBeginAndStopReportsCanBeClosedAndCancelled() throws {
        var events: [NSEvent] = []
        let controller = ThumbWheelScrollController(smoothingFrames: 1, post: {
            events.append(NSEvent(cgEvent: $0)!)
        })
        controller.consume(try report(delta: 1, state: 2))
        controller.finish()
        controller.finish()
        controller.consume(try report(delta: 1, state: 2))
        controller.finish(cancelled: true)
        XCTAssertEqual(events.map(\.phase), [.began, .ended, .began, .cancelled])
    }

    func testNaturalScrollingIsFrozenUntilNextGesture() throws {
        var natural = true
        var deltas: [CGFloat] = []
        let controller = ThumbWheelScrollController(smoothingFrames: 1, naturalScrolling: { natural }) {
            deltas.append(NSEvent(cgEvent: $0)!.scrollingDeltaX)
        }
        controller.deviceDirection = -1
        controller.consume(try report(delta: 1, state: 1))
        natural = false
        controller.consume(try report(delta: 1, state: 2))
        controller.finish()
        controller.consume(try report(delta: 1, state: 1))
        XCTAssertEqual(deltas, [-10, -10, 0, 10])
        controller.finish(cancelled: true)
    }

    func testParserRejectsOtherDevicesRepliesAndMalformedReports() throws {
        let valid = packet(delta: -32768, state: 2)
        XCTAssertEqual(try XCTUnwrap(parse(valid)).delta, -32768)
        XCTAssertNil(ThumbWheelReport(packet: valid, deviceIndex: 2, featureIndex: 8))
        XCTAssertNil(ThumbWheelReport(packet: valid, deviceIndex: 1, featureIndex: 9))
        XCTAssertNil(parse(HIDPPPacket(reportID: 0x11, deviceIndex: 1, featureIndex: 8,
                                      function: 0, softwareID: 10, parameters: valid.parameters)))
        XCTAssertNil(parse(HIDPPPacket(reportID: 0x11, deviceIndex: 1, featureIndex: 8,
                                      function: 0, softwareID: 0, parameters: [0, 1])))
        XCTAssertNil(parse(packet(delta: 1, state: 4)))
    }

    private func packet(delta: Int16, state: UInt8) -> HIDPPPacket {
        let bits = UInt16(bitPattern: delta)
        return HIDPPPacket(reportID: 0x11, deviceIndex: 1, featureIndex: 8,
                           function: 0, softwareID: 0,
                           parameters: [UInt8(bits >> 8), UInt8(bits & 255), 0, 0, state, 0])
    }

    private func parse(_ packet: HIDPPPacket) -> ThumbWheelReport? {
        ThumbWheelReport(packet: packet, deviceIndex: 1, featureIndex: 8)
    }

    func testStalledPostsDoNotQueueAndKeepEveryPixel() throws {
        let queue = DispatchQueue(label: "session"), postQueue = DispatchQueue(label: "post")
        let release = DispatchSemaphore(value: 0)
        let posted = PostedDeltas()
        let controller = ThumbWheelScrollController(queue: queue, postQueue: postQueue, naturalScrolling: { false }) {
            posted.append($0.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
            release.wait()
        }
        let reports = try (0 ..< 3).map { _ in try report(delta: 12, state: 2) }
        queue.sync { for report in reports { controller.consume(report) } }
        Thread.sleep(forTimeInterval: 0.1) // about twelve frames, with the first post stuck
        XCTAssertEqual(posted.values.count, 1)

        for _ in 0 ..< 64 { release.signal() }
        let ending = try report(delta: 0, state: 3)
        queue.sync { controller.consume(ending) }
        waitUntil { !queue.sync { controller.isActive } }
        postQueue.sync {}
        XCTAssertEqual(posted.values.map(abs).reduce(0, +), 360)
    }

    func testTurnAfterAPausePostsWithoutWaitingForAFrame() throws {
        let queue = DispatchQueue(label: "session")
        let posted = PostedDeltas()
        let controller = ThumbWheelScrollController(queue: queue, naturalScrolling: { false }) {
            posted.append($0.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
        }
        let turn = try report(delta: 12, state: 2)
        queue.sync { controller.consume(turn) }
        waitUntil { posted.values.count == 4 } // the last frame stops the timer
        queue.sync {
            controller.consume(turn)
            XCTAssertEqual(posted.values.count, 5)
        }
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date.now.addingTimeInterval(5)
        while !condition(), Date.now < deadline { Thread.sleep(forTimeInterval: 0.005) }
    }

    private func report(delta: Int16, state: UInt8) throws -> ThumbWheelReport {
        try XCTUnwrap(parse(packet(delta: delta, state: state)))
    }
}

private final class PostedDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [Double] = []
    var values: [Double] { lock.withLock { deltas } }
    func append(_ delta: Double) { lock.withLock { deltas.append(delta) } }
}
