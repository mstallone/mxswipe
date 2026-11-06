import ApplicationServices
import Foundation
import OSLog

/// Keeps full-screen Spaces on the displays a Mission Control click didn't touch.
///
/// Opening Mission Control moves every display showing a full-screen Space to that display's desktop.
/// Closing it moves them back, unless the user clicks a window, which leaves them on the desktop even
/// when the window is on another display. So this notes the full-screen displays before MXSwipe opens
/// Mission Control, and when it closes after a click, puts back each one the click wasn't on. Closing
/// it without a click is left to the system.
///
/// Only Mission Control opened from the panel is covered: the Spaces have already moved by the time
/// another trigger's Mission Control can be seen.
final class FullScreenSpaceKeeper: @unchecked Sendable {
    struct Display: Equatable {
        let id: String
        let currentSpace: UInt64
        let fullScreenSpaces: Set<UInt64>
    }

    /// Full-screen Spaces by display.
    private typealias Spaces = [String: UInt64]

    private enum Phase {
        case idle
        /// Waiting for Mission Control to appear.
        case opening(Spaces, deadline: TimeInterval)
        case open(Spaces, clicks: UInt32, clickedDisplay: String?)
    }

    private static let pollInterval = 0.03
    /// How long after a press or release Mission Control has to appear.
    private static let openingTimeout = 1.5
    /// How long a gesture can be held. A mouse that sleeps mid-gesture never reports the release.
    private static let heldGestureTimeout = 60.0
    /// About three seconds of an unreadable Dock, past what its animations cause.
    private static let maximumUnreadableReads = 100

    private let queue: DispatchQueue
    private let displays: () -> [Display]
    private let missionControlState: () -> Bool?
    private let clickCount: () -> UInt32
    private let cursorDisplay: () -> String?
    private let setCurrentSpace: (String, UInt64) -> Void
    private let schedule: (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let now: () -> TimeInterval

    // Confined to `queue`.
    private var phase = Phase.idle
    private var gestureHeld = false
    private var pollScheduled = false
    private var unreadableReads = 0

    /// `queue` carries the Dock's Accessibility reads, so it must not be the one that posts gestures.
    convenience init(queue: DispatchQueue) {
        self.init(
            queue: queue,
            displays: FullScreenSpaceKeeper.managedDisplays,
            missionControlState: DockSwipeController.missionControlState,
            clickCount: { CGEventSource.counterForEventType(.hidSystemState, eventType: .leftMouseDown) },
            cursorDisplay: FullScreenSpaceKeeper.displayUnderCursor,
            setCurrentSpace: FullScreenSpaceKeeper.setCurrentSpace,
            schedule: { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) }
        )
    }

    init(
        queue: DispatchQueue,
        displays: @escaping () -> [Display],
        missionControlState: @escaping () -> Bool?,
        clickCount: @escaping () -> UInt32,
        cursorDisplay: @escaping () -> String?,
        setCurrentSpace: @escaping (String, UInt64) -> Void,
        schedule: @escaping (TimeInterval, @escaping @Sendable () -> Void) -> Void,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.queue = queue
        self.displays = displays
        self.missionControlState = missionControlState
        self.clickCount = clickCount
        self.cursorDisplay = cursorDisplay
        self.setCurrentSpace = setCurrentSpace
        self.schedule = schedule
        self.now = now
    }

    /// Call before posting anything that may open Mission Control. Reads the Spaces on the caller's
    /// queue, so the snapshot is taken before the post. While Mission Control is open no display is in
    /// full screen, so a gesture that closes it has nothing to keep and changes nothing here.
    func prepare() {
        let displays = displays()
        // One entry means "Displays have separate Spaces" is off, so a Space spans every display.
        let spaces = displays.count > 1 ? Self.fullScreenSpaces(of: displays) : [:]
        queue.async { [self] in
            if case .open = phase { return }
            guard !spaces.isEmpty else { return }
            phase = .opening(spaces, deadline: now() + Self.heldGestureTimeout)
            gestureHeld = true
            schedulePoll()
        }
    }

    /// The press or gesture is over, so Mission Control appears soon or not at all.
    func settle() {
        queue.async { [self] in
            guard gestureHeld else { return }
            gestureHeld = false
            if case let .opening(spaces, _) = phase {
                phase = .opening(spaces, deadline: now() + Self.openingTimeout)
            }
        }
    }

    private static func fullScreenSpaces(of displays: [Display]) -> Spaces {
        var spaces: Spaces = [:]
        for display in displays where display.fullScreenSpaces.contains(display.currentSpace) {
            spaces[display.id] = display.currentSpace
        }
        return spaces
    }

    private func schedulePoll() {
        guard !pollScheduled else { return }
        pollScheduled = true
        schedule(Self.pollInterval) { [self] in poll() }
    }

    private func poll() {
        pollScheduled = false
        switch phase {
        case .idle:
            return
        case let .opening(spaces, deadline):
            if missionControlState() == true {
                phase = .open(spaces, clicks: clickCount(), clickedDisplay: nil)
                unreadableReads = 0
            } else if now() >= deadline {
                phase = .idle
                return
            }
        case .open(let spaces, var clicks, var clickedDisplay):
            // Read before the state: a click can close Mission Control within one poll, and the cursor
            // is still where it clicked.
            let count = clickCount()
            if count != clicks {
                clicks = count
                clickedDisplay = cursorDisplay()
            }
            let state = missionControlState()
            // An unreadable Dock, which is common while it animates, doesn't mean it closed.
            unreadableReads = state == nil ? unreadableReads + 1 : 0
            if unreadableReads >= Self.maximumUnreadableReads {
                phase = .idle
                return
            }
            if state == false {
                if let clickedDisplay {
                    phase = .idle
                    restore(spaces, except: clickedDisplay)
                    return
                }
                guard gestureHeld else {
                    phase = .idle
                    return
                }
                // Reversed without letting go, which can still open it again.
                phase = .opening(spaces, deadline: now() + Self.heldGestureTimeout)
            } else {
                phase = .open(spaces, clicks: clicks, clickedDisplay: clickedDisplay)
            }
        }
        schedulePoll()
    }

    private func restore(_ spaces: Spaces, except clickedDisplay: String) {
        for display in displays() where display.id != clickedDisplay {
            guard let space = spaces[display.id], space != display.currentSpace,
                  display.fullScreenSpaces.contains(space) else { continue }
            setCurrentSpace(display.id, space)
        }
    }
}

// MARK: System

extension FullScreenSpaceKeeper {
    private static let logger = Logger(subsystem: "com.mattstallone.mxmasterinput", category: "Spaces")

    /// SkyLight's Space calls, resolved at run time so a macOS without them leaves full-screen Spaces
    /// to the system instead of failing to launch.
    private struct SkyLight: @unchecked Sendable {
        let connection: Int32
        let copyManagedDisplaySpaces: @convention(c) (Int32) -> Unmanaged<CFArray>?
        let managedDisplaySetCurrentSpace: @convention(c) (Int32, CFString, UInt64) -> Int32

        static let shared: SkyLight? = {
            // Never closed: the function pointers live as long as the process.
            guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL),
                  let mainConnection = dlsym(library, "SLSMainConnectionID"),
                  let copySpaces = dlsym(library, "SLSCopyManagedDisplaySpaces"),
                  let setSpace = dlsym(library, "SLSManagedDisplaySetCurrentSpace") else { return nil }
            typealias MainConnection = @convention(c) () -> Int32
            return SkyLight(
                connection: unsafeBitCast(mainConnection, to: MainConnection.self)(),
                copyManagedDisplaySpaces: unsafeBitCast(copySpaces, to: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self),
                managedDisplaySetCurrentSpace: unsafeBitCast(setSpace, to: (@convention(c) (Int32, CFString, UInt64) -> Int32).self)
            )
        }()
    }

    /// Each display's Spaces, or nothing on a macOS not yet validated.
    static func managedDisplays() -> [Display] {
        // Like the DockSwipe layouts, these are private; each major release needs revalidating.
        if #available(macOS 28, *) { return [] }
        guard let skyLight = SkyLight.shared,
              let entries = skyLight.copyManagedDisplaySpaces(skyLight.connection)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return displays(from: entries)
    }

    /// Parses `SLSCopyManagedDisplaySpaces`. A Space of type 4 is full screen or Split View.
    static func displays(from entries: [[String: Any]]) -> [Display] {
        entries.compactMap { entry in
            guard let id = entry["Display Identifier"] as? String,
                  let current = (entry["Current Space"] as? [String: Any])?["id64"] as? UInt64,
                  let spaces = entry["Spaces"] as? [[String: Any]] else { return nil }
            let fullScreen = spaces.compactMap { $0["type"] as? Int == 4 ? $0["id64"] as? UInt64 : nil }
            return Display(id: id, currentSpace: current, fullScreenSpaces: Set(fullScreen))
        }
    }

    /// The display under the cursor, in the form `SLSCopyManagedDisplaySpaces` identifies it.
    static func displayUnderCursor() -> String? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count == 1,
              let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func setCurrentSpace(display: String, space: UInt64) {
        guard let skyLight = SkyLight.shared else { return }
        let error = skyLight.managedDisplaySetCurrentSpace(skyLight.connection, display as CFString, space)
        if error != 0 { logger.error("Couldn't restore a full-screen Space: \(error)") }
    }
}
