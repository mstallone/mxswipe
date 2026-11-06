import Carbon.HIToolbox
import XCTest
@testable import MXSwipe

final class DockSwipeControllerTests: XCTestCase {
    private typealias Swipe = DockSwipeController.Swipe

    private var swipes: [Swipe] = []
    private var keys: [Int] = []
    private var dockAvailable = true
    private var naturalScrolling = true

    private func makeController() -> DockSwipeController {
        DockSwipeController(
            post: { [unowned self] in swipes.append($0); return dockAvailable },
            postControlArrow: { [unowned self] in keys.append($0); return true },
            naturalScrolling: { [unowned self] in naturalScrolling }
        )
    }

    func testOnlyMissionControlInputsPrepareTheSpaceKeeper() {
        var prepared = 0
        let keeper = FullScreenSpaceKeeper(
            queue: DispatchQueue(label: "test"),
            displays: {
                prepared += 1
                return []
            },
            missionControlState: { false },
            clickCount: { 0 },
            cursorDisplay: { nil },
            setCurrentSpace: { _, _ in },
            schedule: { _, _ in }
        )
        let controller = DockSwipeController(
            post: { _ in true },
            postControlArrow: { _ in true },
            naturalScrolling: { true },
            spaceKeeper: keeper
        )

        controller.handle(.began(axis: .horizontal, delta: -30))
        controller.handle(.ended)
        XCTAssertEqual(prepared, 0)

        controller.handle(.began(axis: .vertical, delta: -30))
        controller.handle(.ended)
        XCTAssertEqual(prepared, 1)

        controller.tap()
        XCTAssertEqual(prepared, 2)
    }

    func testForwardMotionBeginsChangesAndCommits() {
        let controller = makeController()
        controller.handle(.began(axis: .horizontal, delta: -30))
        controller.handle(.changed(delta: -100))
        controller.handle(.ended)

        XCTAssertEqual(swipes.map(\.phase), [.began, .changed, .ended])
        XCTAssertEqual(swipes.map(\.axis), [.horizontal, .horizontal, .horizontal])
        assertProgress([0.072, 0.312, 0.312])
        XCTAssertEqual(swipes.last?.exitSpeed ?? 0, 24, accuracy: 1e-9)
    }

    func testReleaseWhileReversingSpringsBack() {
        let controller = makeController()
        controller.handle(.began(axis: .horizontal, delta: -30))
        controller.handle(.changed(delta: -100))
        controller.handle(.changed(delta: 80))
        controller.handle(.ended)

        XCTAssertEqual(swipes.map(\.phase), [.began, .changed, .changed, .cancelled])
        assertProgress([0.072, 0.312, 0.12, 0.12])
        XCTAssertEqual(swipes.last?.exitSpeed ?? 0, -19.2, accuracy: 1e-9)
    }

    func testReleaseAtOriginSpringsBack() {
        let controller = makeController()
        controller.handle(.began(axis: .horizontal, delta: -30))
        controller.handle(.changed(delta: 30))
        controller.handle(.ended)
        XCTAssertEqual(swipes.last?.phase, .cancelled)
    }

    func testOnlyEndingPhasesCarryExitSpeed() {
        let controller = makeController()
        controller.handle(.began(axis: .vertical, delta: -30))
        controller.handle(.changed(delta: -50))
        controller.handle(.ended)
        XCTAssertEqual(swipes.map(\.exitSpeed).prefix(2), [0, 0])
        XCTAssertNotEqual(swipes.last?.exitSpeed, 0)
    }

    func testEveryReversalIsPosted() {
        let controller = makeController()
        controller.handle(.began(axis: .horizontal, delta: -30))
        for dx in [100, -100, 100, -100, 100, -100] { controller.handle(.changed(delta: dx)) }
        controller.handle(.ended)
        XCTAssertEqual(swipes.map(\.phase), [.began] + Array(repeating: .changed, count: 6) + [.ended])
    }

    func testZeroMotionIsIgnored() {
        let controller = makeController()
        controller.handle(.began(axis: .horizontal, delta: -30))
        controller.handle(.changed(delta: 0))
        XCTAssertEqual(swipes.count, 1)
    }

    func testOppositeSequentialSwipesAreIndependent() {
        let controller = makeController()
        controller.handle(.began(axis: .horizontal, delta: -100))
        controller.handle(.ended)
        controller.handle(.began(axis: .horizontal, delta: 100))
        controller.handle(.ended)

        XCTAssertEqual(swipes.map(\.phase), [.began, .ended, .began, .ended])
        assertProgress([0.24, 0.24, -0.24, -0.24])
    }

    func testCancelClosesTheActiveSwipe() {
        let controller = makeController()
        controller.handle(.began(axis: .horizontal, delta: 40))
        controller.handle(.changed(delta: -10))
        controller.handle(.cancelled)
        controller.cancel()

        XCTAssertEqual(swipes.map(\.phase), [.began, .changed, .cancelled])
        XCTAssertEqual(swipes.last?.progress ?? 0, -0.072, accuracy: 1e-9)
    }

    func testNewSwipeCancelsAnOverlappingOne() {
        let controller = makeController()
        controller.handle(.began(axis: .horizontal, delta: -30))
        controller.handle(.began(axis: .vertical, delta: -30))
        controller.cancel()

        XCTAssertEqual(swipes.map(\.axis), [.horizontal, .horizontal, .vertical, .vertical])
        XCTAssertEqual(swipes.map(\.phase), [.began, .cancelled, .began, .cancelled])
    }

    func testUpwardMotionOpensMissionControl() {
        let controller = makeController()
        controller.handle(.began(axis: .vertical, delta: -30))
        controller.handle(.changed(delta: -100))
        controller.handle(.ended)

        XCTAssertEqual(swipes.map(\.phase), [.began, .changed, .ended])
        assertProgress([-0.072, -0.312, -0.312])
    }

    func testDownwardMotionClosesMissionControl() {
        let controller = makeController()
        controller.handle(.began(axis: .vertical, delta: 45))
        controller.handle(.changed(delta: 100))
        controller.handle(.ended)

        XCTAssertEqual(swipes.map(\.phase), [.began, .changed, .ended])
        assertProgress([0.108, 0.348, 0.348])
    }

    func testNaturalScrollingIsFrozenWhenTheSwipeBegins() {
        let controller = makeController()
        naturalScrolling = false
        controller.handle(.began(axis: .horizontal, delta: -30))
        naturalScrolling = true
        controller.handle(.changed(delta: -30))
        controller.handle(.ended)
        XCTAssertEqual(swipes.map(\.naturalScrolling), [false, false, false])
    }

    func testFallsBackToShortcutsOnlyWhenTheSwipeCannotBegin() {
        dockAvailable = false
        let controller = makeController()
        controller.handle(.began(axis: .horizontal, delta: -30))
        controller.handle(.changed(delta: 100))
        controller.handle(.ended)

        XCTAssertEqual(swipes.map(\.phase), [.began])
        XCTAssertEqual(keys, [kVK_LeftArrow])
    }

    func testFallbackFollowsTheFingerWhenProgressReturnsToZero() {
        dockAvailable = false
        let controller = makeController()
        controller.handle(.began(axis: .horizontal, delta: 30))
        controller.handle(.changed(delta: -30))
        controller.handle(.ended)
        XCTAssertEqual(keys, [kVK_RightArrow])
    }

    func testVerticalFallbackTogglesMissionControl() {
        dockAvailable = false
        let controller = makeController()
        controller.handle(.began(axis: .vertical, delta: -30))
        controller.handle(.changed(delta: 100))
        controller.handle(.ended)
        XCTAssertEqual(keys, [kVK_UpArrow])
    }

    func testTapOpensMissionControlWithTheShortcut() {
        makeController().tap()
        XCTAssertEqual(swipes, [])
        XCTAssertEqual(keys, [kVK_UpArrow])
    }

    func testLegacyEventCarriesPhaseProgressAxisAndExitSpeed() throws {
        let swipe = Swipe(axis: .vertical, progress: -0.25, phase: .ended, exitSpeed: 12)
        let (dock, gesture) = try XCTUnwrap(DockSwipeController.legacyEvents(for: swipe))
        func field(_ event: CGEvent, _ raw: UInt32) -> Double { event.getDoubleValueField(CGEventField(rawValue: raw)!) }

        XCTAssertEqual(field(gesture, 55), 29)
        XCTAssertEqual(field(dock, 55), 30)
        XCTAssertEqual(field(dock, 110), 23)
        XCTAssertEqual(field(dock, 132), 4)
        XCTAssertEqual(field(dock, 124), -0.25)
        XCTAssertEqual(dock.getIntegerValueField(CGEventField(rawValue: 135)!), Int64(Float(-0.25).bitPattern))
        XCTAssertEqual(field(dock, 119), 2.802596928649634e-45)
        XCTAssertEqual(field(dock, 123), 2)
        XCTAssertEqual(field(dock, 129), 12)
    }

    private func assertProgress(_ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(swipes.count, expected.count, file: file, line: line)
        for (swipe, value) in zip(swipes, expected) {
            XCTAssertEqual(swipe.progress, value, accuracy: 1e-9, file: file, line: line)
        }
    }
}
