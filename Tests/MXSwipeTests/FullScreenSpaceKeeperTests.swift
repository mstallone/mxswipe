import XCTest
@testable import MXSwipe

final class FullScreenSpaceKeeperTests: XCTestCase {
    private typealias Display = FullScreenSpaceKeeper.Display

    private let queue = DispatchQueue(label: "FullScreenSpaceKeeperTests")
    private var displays: [Display] = []
    private var missionControlState: Bool? = false
    private var clicks: UInt32 = 0
    private var cursor: String? = "external"
    private var restored: [String] = []
    private var polls: [@Sendable () -> Void] = []
    private var time = 0.0

    override func setUp() {
        displays = [display("internal", current: 2, fullScreen: [2]), display("external", current: 9)]
    }

    private func display(_ id: String, current: UInt64, fullScreen: Set<UInt64> = []) -> Display {
        Display(id: id, currentSpace: current, fullScreenSpaces: fullScreen)
    }

    private func makeKeeper() -> FullScreenSpaceKeeper {
        FullScreenSpaceKeeper(
            queue: queue,
            displays: { [unowned self] in displays },
            missionControlState: { [unowned self] in missionControlState },
            clickCount: { [unowned self] in clicks },
            cursorDisplay: { [unowned self] in cursor },
            setCurrentSpace: { [unowned self] in restored.append("\($0):\($1)") },
            schedule: { [unowned self] _, work in polls.append(work) },
            now: { [unowned self] in time }
        )
    }

    private func prepare(_ keeper: FullScreenSpaceKeeper) {
        keeper.prepare()
        queue.sync {}
    }

    private func settle(_ keeper: FullScreenSpaceKeeper) {
        keeper.settle()
        queue.sync {}
    }

    private func poll() {
        guard !polls.isEmpty else { return XCTFail("Nothing is scheduled") }
        polls.removeFirst()()
    }

    /// Mission Control opens from a tap, and the full-screen display moves to its desktop.
    private func open(_ keeper: FullScreenSpaceKeeper) {
        prepare(keeper)
        settle(keeper)
        missionControlState = true
        poll()
        displays[0] = display("internal", current: 1, fullScreen: [2])
    }

    private func click(on displayID: String) {
        clicks += 1
        cursor = displayID
        missionControlState = false
    }

    func testClickOnAnotherDisplayRestoresTheFullScreenSpace() {
        let keeper = makeKeeper()
        open(keeper)
        click(on: "external")
        poll()
        XCTAssertEqual(restored, ["internal:2"])
        XCTAssertTrue(polls.isEmpty)
    }

    func testClickOnTheFullScreenDisplayKeepsItsChoice() {
        let keeper = makeKeeper()
        open(keeper)
        click(on: "internal")
        poll()
        XCTAssertEqual(restored, [])
    }

    func testClickDisplayIsReadAtTheClickNotAtTheClose() {
        let keeper = makeKeeper()
        open(keeper)
        click(on: "internal")
        missionControlState = true
        poll()
        cursor = "external"
        missionControlState = false
        poll()
        XCTAssertEqual(restored, [])
    }

    func testLastClickDecides() {
        let keeper = makeKeeper()
        open(keeper)
        click(on: "internal")
        missionControlState = true
        poll()
        click(on: "external")
        poll()
        XCTAssertEqual(restored, ["internal:2"])
    }

    func testClosingWithoutAClickIsLeftToTheSystem() {
        let keeper = makeKeeper()
        open(keeper)
        missionControlState = false
        poll()
        XCTAssertEqual(restored, [])
        XCTAssertTrue(polls.isEmpty)
    }

    func testClickBeforeMissionControlOpensIsIgnored() {
        let keeper = makeKeeper()
        clicks = 5
        open(keeper)
        missionControlState = false
        poll()
        XCTAssertEqual(restored, [])
    }

    func testUnreadableDockIsNotAClose() {
        let keeper = makeKeeper()
        open(keeper)
        missionControlState = nil
        poll()
        XCTAssertEqual(polls.count, 1)
        click(on: "external")
        poll()
        XCTAssertEqual(restored, ["internal:2"])
    }

    func testDisplayAlreadyBackIsLeftAlone() {
        let keeper = makeKeeper()
        open(keeper)
        displays[0] = display("internal", current: 2, fullScreen: [2])
        click(on: "external")
        poll()
        XCTAssertEqual(restored, [])
    }

    func testSpaceClosedWhileMissionControlWasOpenIsNotRestored() {
        let keeper = makeKeeper()
        open(keeper)
        displays[0] = display("internal", current: 1)
        click(on: "external")
        poll()
        XCTAssertEqual(restored, [])
    }

    func testNoFullScreenDisplayMeansNoWatching() {
        let keeper = makeKeeper()
        displays = [display("internal", current: 1, fullScreen: [2]), display("external", current: 9)]
        prepare(keeper)
        XCTAssertTrue(polls.isEmpty)
    }

    func testSpacesSpanningDisplaysAreLeftToTheSystem() {
        let keeper = makeKeeper()
        displays = [display("Main", current: 2, fullScreen: [2])]
        prepare(keeper)
        XCTAssertTrue(polls.isEmpty)
    }

    func testHeldGestureWaitsUntilReleased() {
        let keeper = makeKeeper()
        prepare(keeper)
        time = 59
        poll()
        XCTAssertEqual(polls.count, 1)
    }

    func testGestureThatNeverReportsItsReleaseStopsWatching() {
        let keeper = makeKeeper()
        prepare(keeper)
        time = 60
        poll()
        XCTAssertTrue(polls.isEmpty)
    }

    func testDockThatStaysUnreadableStopsWatching() {
        let keeper = makeKeeper()
        open(keeper)
        missionControlState = nil
        for _ in 0..<100 { poll() }
        XCTAssertTrue(polls.isEmpty)
    }

    func testEmptySnapshotKeepsThePendingWatch() {
        let keeper = makeKeeper()
        prepare(keeper)
        settle(keeper)
        displays[0] = display("internal", current: 1, fullScreen: [2])
        prepare(keeper)
        settle(keeper)
        missionControlState = true
        poll()
        click(on: "external")
        poll()
        XCTAssertEqual(restored, ["internal:2"])
    }

    func testHeldGestureCanReverseAndOpenAgain() {
        let keeper = makeKeeper()
        prepare(keeper)
        missionControlState = true
        poll()
        missionControlState = false
        poll()
        XCTAssertEqual(restored, [])
        missionControlState = true
        poll()
        settle(keeper)
        displays[0] = display("internal", current: 1, fullScreen: [2])
        poll()
        click(on: "external")
        poll()
        XCTAssertEqual(restored, ["internal:2"])
    }

    func testMissionControlThatNeverOpensStopsWatching() {
        let keeper = makeKeeper()
        prepare(keeper)
        settle(keeper)
        time = 1.4
        poll()
        XCTAssertEqual(polls.count, 1)
        time = 1.5
        poll()
        XCTAssertTrue(polls.isEmpty)
        XCTAssertEqual(restored, [])
    }

    func testPreparingAgainRetakesTheSnapshotWithoutASecondWatch() {
        let keeper = makeKeeper()
        prepare(keeper)
        settle(keeper)
        displays[0] = display("internal", current: 3, fullScreen: [2, 3])
        prepare(keeper)
        XCTAssertEqual(polls.count, 1)

        settle(keeper)
        missionControlState = true
        poll()
        displays[0] = display("internal", current: 1, fullScreen: [2, 3])
        click(on: "external")
        poll()
        XCTAssertEqual(restored, ["internal:3"])
    }

    func testParsesManagedDisplaySpaces() {
        func space(_ id: Int, type: Int) -> [String: Any] {
            ["id64": NSNumber(value: id), "type": NSNumber(value: type)]
        }
        let parsed = FullScreenSpaceKeeper.displays(from: [
            ["Display Identifier": "37D8832A", "Current Space": space(5239, type: 4),
             "Spaces": [space(5232, type: 0), space(5239, type: 4)]],
            ["Display Identifier": "malformed"],
        ])
        XCTAssertEqual(parsed, [Display(id: "37D8832A", currentSpace: 5239, fullScreenSpaces: [5239])])
    }
}
