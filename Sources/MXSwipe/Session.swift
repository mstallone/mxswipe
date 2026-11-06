import Foundation
import OSLog

/// What the session reports after connecting.
enum SessionEvent: Sendable {
    case battery(Int?)
    /// The mouse's wireless link dropped, usually because it went to sleep.
    case asleep
    /// The mouse woke and its configuration was reapplied.
    case awake
    /// The mouse woke, but it rejected its configuration.
    case recoveryFailed
    /// The receiver was unplugged. The session has stopped.
    case receiverRemoved
}

struct ConnectedMouse: Sendable {
    let name: String
    let batteryPercent: Int?
    let hapticSupported: Bool
    let hapticDisabled: Bool
    let panelDiverted: Bool
}

/// Descriptions are shown under the mouse's name in the menu, so they don't repeat it.
enum SessionError: LocalizedError {
    case noReceiver
    case unableToOpen(String)
    case noMouse
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noReceiver: "No Logitech receiver is connected."
        case .unableToOpen: "Couldn’t open the Logitech receiver."
        case .noMouse: "Not responding. Move it to wake it."
        case .configurationFailed: "It didn’t accept its configuration."
        }
    }
}

/// The HID++ conversation with one MX Master 4: finds it behind the receiver, diverts the Sense Panel and
/// thumb wheel to this app, turns off the panel's haptic click, and turns their reports into Dock swipes
/// and scroll gestures. Hands the panel and wheel back on stop (the haptic click returns when the mouse
/// next sleeps), and reapplies everything whenever the mouse wakes.
///
/// Requests are synchronous: they block the session queue until the reply arrives on the HID queue.
/// Every other piece of state is confined to the session queue.
final class MXMasterSession: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.mattstallone.mxmasterinput", category: "HID")

    private enum ExpectedReply {
        case feature(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8)
        case receiverRegister(command: UInt8, address: UInt8)
    }

    private final class PendingRequest {
        let expected: ExpectedReply
        let replied = DispatchSemaphore(value: 0)
        var reply: HIDPPPacket?
        init(_ expected: ExpectedReply) { self.expected = expected }
    }

    private let queue = DispatchQueue(label: "com.mattstallone.mxmasterinput.session", qos: .userInteractive)
    /// Dock swipes and shortcuts post from their own queue: an Accessibility call can stall, and HID
    /// input must keep flowing meanwhile.
    private let outputQueue = DispatchQueue(label: "com.mattstallone.mxmasterinput.output", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pending: PendingRequest?

    private let recognizer: ContinuousGestureRecognizer
    private let dockSwipe: DockSwipeController
    private lazy var thumbScroll = ThumbWheelScrollController(queue: queue)
    private var onEvent: (@Sendable (SessionEvent) -> Void)?

    private var device: HIDDevice?
    private var deviceIndex: UInt8 = 0
    private var activeMode = false
    private var started = false
    private var controlsIndex: UInt8?
    private var panelHeld = false
    private var panelDiverted = false
    /// The receiver reported the link down. A mouse forgets its diversion when its link sleeps.
    private var asleep = false
    private var battery: (index: UInt8, feature: Battery.Feature)?
    private var batterySupportsPercentage = false
    private var thumbWheelIndex: UInt8?
    private var originalThumbReporting: [UInt8]?
    private var thumbIdleGeneration = 0
    private var recoveryGeneration = 0
    private var recoveryScheduled = false

    init() {
        recognizer = ContinuousGestureRecognizer(
            // Long enough for a raw-XY report queued before the press to arrive and be discarded.
            motionActivationDelay: 0.06,
            allowsDownwardGesture: DockSwipeController.isMissionControlOpen
        )
        let spaceQueue = DispatchQueue(label: "com.mattstallone.mxmasterinput.spaces", qos: .userInitiated)
        dockSwipe = DockSwipeController(spaceKeeper: FullScreenSpaceKeeper(queue: spaceQueue))
    }

    /// Connects to the first MX Master 4 found. In observation mode nothing on the mouse is changed and
    /// no events are posted; the hardware probe test uses it.
    func start(activeMode: Bool = true, onEvent: @escaping @Sendable (SessionEvent) -> Void) async throws -> ConnectedMouse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if started { stopOnQueue() }
                self.onEvent = onEvent
                self.activeMode = activeMode
                do {
                    let mouse = try connect()
                    started = true
                    continuation.resume(returning: mouse)
                } catch {
                    stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stopOnQueue()
                continuation.resume()
            }
        }
    }

    /// For app termination, when there is no time to await. Also waits for the cancelled swipe to post,
    /// so quitting mid-gesture can't leave the Dock between Spaces.
    func stopSynchronously() {
        queue.sync { stopOnQueue() }
        outputQueue.sync {}
    }

    // MARK: Connecting

    private func connect() throws -> ConnectedMouse {
        let candidates = HIDDevice.hidppInterfaces()
        Self.logger.notice("Found \(candidates.count) HID++ interfaces")
        guard !candidates.isEmpty else { throw SessionError.noReceiver }

        var openError: Error?
        for candidate in candidates {
            Self.logger.notice("""
                Opening product \(candidate.productID) usage \(candidate.usagePage):\(candidate.usage) \
                over \(candidate.transport, privacy: .public)
                """)
            do {
                try candidate.open(
                    onReport: { [weak self] in self?.receive($0) },
                    onRemoval: { [weak self] in
                        guard let self else { return }
                        queue.async { self.receiverRemoved() }
                    }
                )
            } catch {
                Self.logger.error("Open failed: \(error.localizedDescription, privacy: .public)")
                openError = error
                continue
            }
            device = candidate

            // A receiver has up to six paired devices; a directly connected device answers at 0xFF.
            let isReceiver = candidate.productID == Receiver.boltProductID
            for index: UInt8 in isReceiver ? [1, 2, 3, 4, 5, 6] : [0xFF, 1, 2, 3, 4, 5, 6] {
                deviceIndex = index
                // The first wireless reply can take nearly a second, even when the receiver accepts the
                // request immediately.
                guard let controls = findFeature(FeatureID.reprogrammableControls, timeout: 2) else { continue }
                controlsIndex = controls
                let name = queryDeviceName() ?? ""
                Self.logger.notice("Slot \(index): \(name, privacy: .public)")
                guard name.localizedCaseInsensitiveContains("MX Master 4") else {
                    controlsIndex = nil
                    continue
                }
                return try configure(name: name, isReceiver: isReceiver)
            }
            candidate.close()
            device = nil
            controlsIndex = nil
        }
        if let openError { throw SessionError.unableToOpen(openError.localizedDescription) }
        throw SessionError.noMouse
    }

    private func configure(name: String, isReceiver: Bool) throws -> ConnectedMouse {
        guard panelIsDivertable() else { throw SessionError.configurationFailed("no divertable Sense Panel") }
        let hapticIndex = findFeature(FeatureID.haptic, timeout: 0.8)
        if activeMode {
            guard let hapticIndex else { throw SessionError.configurationFailed("no haptic feature") }
            guard disableHaptics(hapticIndex) else { throw SessionError.configurationFailed("haptics stayed on") }
            guard setPanelReporting(SensePanel.divertWithRawXY) else { throw SessionError.configurationFailed("panel not diverted") }
            panelDiverted = true
            if isReceiver, !enableReceiverWirelessNotifications() {
                throw SessionError.configurationFailed("receiver notifications unavailable")
            }
            guard configureThumbWheel() else { throw SessionError.configurationFailed("thumb wheel not diverted") }
        }
        return ConnectedMouse(name: name, batteryPercent: queryBatteryPercent(), hapticSupported: hapticIndex != nil,
                              hapticDisabled: activeMode, panelDiverted: panelDiverted)
    }

    private func stopOnQueue() {
        recoveryGeneration += 1
        recoveryScheduled = false
        cancelThumbScroll()
        if !asleep {
            // The first request after an idle stretch waits for the link to wake, which can take most
            // of a second; the second finds it awake.
            var timeout = 2.0
            if let thumbWheelIndex, let originalThumbReporting {
                _ = request(thumbWheelIndex, function: 2, originalThumbReporting, timeout: timeout)
                timeout = 0.5
            }
            if panelDiverted { _ = setPanelReporting(SensePanel.restoreDefault, timeout: timeout) }
        }
        thumbWheelIndex = nil
        originalThumbReporting = nil
        panelDiverted = false
        asleep = false
        cancelGesture()
        device?.close()
        device = nil
        controlsIndex = nil
        battery = nil
        batterySupportsPercentage = false
        activeMode = false
        started = false
        onEvent = nil
    }

    private func receiverRemoved() {
        guard started else { return }
        Self.logger.notice("Receiver removed")
        let onEvent = onEvent, removed = device
        // Detach first, so the restoring requests in stop fail at once instead of timing out.
        device = nil
        stopOnQueue()
        removed?.close()
        onEvent?(.receiverRemoved)
    }

    // MARK: Features

    private func findFeature(_ id: UInt16, timeout: TimeInterval = 0.8) -> UInt8? {
        guard let index = request(0, function: 0, id.bigEndianBytes + [0], timeout: timeout)?.parameters.first,
              index != 0 else { return nil }
        return index
    }

    private func queryDeviceName() -> String? {
        guard let feature = findFeature(FeatureID.deviceName),
              let length = request(feature, function: 0, [0, 0, 0])?.parameters.first.map(Int.init), length > 0
        else { return nil }
        var bytes: [UInt8] = []
        while bytes.count < length {
            guard let chunk = request(feature, function: 1, [UInt8(clamping: bytes.count), 0, 0])?
                .parameters.prefix(length - bytes.count), !chunk.isEmpty else { break }
            bytes += chunk
        }
        return String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func panelIsDivertable() -> Bool {
        guard let controlsIndex, let count = request(controlsIndex, function: 0, [])?.parameters.first else { return false }
        for index in 0 ..< min(Int(count), 32) {
            guard let info = request(controlsIndex, function: 1, [UInt8(index)], timeout: 0.5)?.parameters,
                  info.count >= 9, unsigned16(info[0], info[1]) == SensePanel.controlID else { continue }
            return info[4] & 0x20 != 0 // divertable
        }
        return false
    }

    private func disableHaptics(_ index: UInt8) -> Bool {
        request(index, function: 2, SensePanel.hapticOff, timeout: 1) != nil
    }

    private func setPanelReporting(_ flags: UInt8, timeout: TimeInterval = 1) -> Bool {
        guard let controlsIndex else { return false }
        return request(controlsIndex, function: 3, SensePanel.controlID.bigEndianBytes + [flags, 0, 0], timeout: timeout) != nil
    }

    private func queryBatteryPercent() -> Int? {
        if battery == nil {
            for feature in [Battery.Feature.unified, .levelStatus] {
                if let index = findFeature(feature.id) {
                    battery = (index, feature)
                    break
                }
            }
        }
        guard let (index, feature) = battery else { return nil }
        if feature == .unified, !batterySupportsPercentage {
            guard let capabilities = request(index, function: 0, []),
                  Battery.supportsPercentage(capabilities.parameters) else { return nil }
        }
        batterySupportsPercentage = true
        return request(index, function: feature.statusFunction, []).flatMap { Battery.percent(from: $0.parameters, feature: feature) }
    }

    /// Wake notifications are off by default on the Bolt receiver. Register 0x00 is shared by every HID++
    /// client with no ownership, so the bit is left on at stop rather than pulled from under another app.
    private func enableReceiverWirelessNotifications() -> Bool {
        let flag = Receiver.wirelessNotificationsFlag
        guard let current = receiverRegister(Receiver.readShortRegister)?.parameters, current.count >= 3 else { return false }
        if current[1] & flag != 0 { return true }
        var updated = Array(current.prefix(3))
        updated[1] |= flag
        guard receiverRegister(Receiver.writeShortRegister, updated) != nil,
              let verified = receiverRegister(Receiver.readShortRegister)?.parameters, verified.count >= 3 else { return false }
        return verified[1] & flag != 0
    }

    /// Diverts the thumb wheel and asks for uninverted rotation; natural scrolling is applied once, when
    /// the scroll event is made. Only the writable inversion bit of the original status is kept, and it
    /// is kept across wakes, so stop restores what the mouse had before this app.
    private func configureThumbWheel() -> Bool {
        guard let index = findFeature(FeatureID.thumbWheel),
              let info = request(index, function: 0, [])?.parameters, info.count >= 8,
              let status = request(index, function: 1, [])?.parameters, status.count >= 2 else { return false }
        let resolution = Int(unsigned16(info[2], info[3]))
        guard resolution > 0 else { return false }
        thumbWheelIndex = index
        if originalThumbReporting == nil { originalThumbReporting = [status[0] & 1, status[1] & 1] }
        thumbScroll.pixelsPerUnit = 1200 / Double(resolution) // 1,200 px per revolution
        thumbScroll.deviceDirection = info[4] == 0 ? -1 : 1
        guard request(index, function: 2, [1, 0]) != nil,
              let verified = request(index, function: 1, [])?.parameters, verified.count >= 2 else { return false }
        return verified[0] & 1 == 1 && verified[1] & 1 == 0
    }

    // MARK: Wake

    /// Diversion, haptics and wheel reporting are volatile: the mouse forgets them when its link sleeps,
    /// while the receiver and this session stay open. Reapply them when the receiver says it woke.
    private func scheduleRecovery() {
        guard started, activeMode, !recoveryScheduled else { return }
        recoveryScheduled = true
        recoveryGeneration += 1
        let generation = recoveryGeneration
        cancelThumbScroll()
        cancelGesture()
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.recover(generation: generation, attempt: 0) }
    }

    private func recover(generation: Int, attempt: Int) {
        guard started, activeMode, recoveryScheduled, generation == recoveryGeneration else { return }
        controlsIndex = findFeature(FeatureID.reprogrammableControls)
        let hapticsOff = findFeature(FeatureID.haptic).map(disableHaptics) == true
        let diverted = controlsIndex != nil && setPanelReporting(SensePanel.divertWithRawXY)
        let thumbWheel = configureThumbWheel()
        if hapticsOff, diverted, thumbWheel {
            panelDiverted = true
            recoveryScheduled = false
            onEvent?(.awake)
            onEvent?(.battery(queryBatteryPercent()))
            return
        }
        let retryDelays: [TimeInterval] = [0.5, 1.5]
        guard attempt < retryDelays.count else {
            recoveryScheduled = false
            onEvent?(.recoveryFailed)
            return
        }
        queue.asyncAfter(deadline: .now() + retryDelays[attempt]) { [weak self] in
            self?.recover(generation: generation, attempt: attempt + 1)
        }
    }

    // MARK: Requests

    private func request(_ featureIndex: UInt8, function: UInt8, _ parameters: [UInt8], timeout: TimeInterval = 0.8) -> HIDPPPacket? {
        let report = HIDPPPacket.request(deviceIndex: deviceIndex, featureIndex: featureIndex, function: function, parameters: parameters)
        let expected = ExpectedReply.feature(deviceIndex: deviceIndex, featureIndex: featureIndex, function: function)
        guard let reply = send(report, expecting: expected, timeout: timeout), !reply.isError else { return nil }
        return reply
    }

    private func receiverRegister(_ command: UInt8, _ parameters: [UInt8] = []) -> HIDPPPacket? {
        let report = HIDPPPacket.shortRegisterRequest(deviceIndex: Receiver.index, command: command,
                                                      address: Receiver.notificationsRegister, parameters: parameters)
        return send(report, expecting: .receiverRegister(command: command, address: Receiver.notificationsRegister), timeout: 0.8)
    }

    private func send(_ report: Data, expecting expected: ExpectedReply, timeout: TimeInterval) -> HIDPPPacket? {
        guard let device else { return nil }
        let request = PendingRequest(expected)
        guard pendingLock.withLock({ () -> Bool in
            guard pending == nil else { return false }
            pending = request
            return true
        }) else { return nil }
        defer { pendingLock.withLock { if pending === request { pending = nil } } }

        let sent = ProcessInfo.processInfo.systemUptime
        do {
            try device.send(report)
        } catch {
            Self.logger.error("Send failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let result = request.replied.wait(timeout: .now() + timeout)
        guard result == .success, let reply = pendingLock.withLock({ request.reply }) else {
            Self.logger.error("Timed out: \(String(describing: expected), privacy: .public)")
            return nil
        }
        if reply.isError {
            Self.logger.error("Error \(reply.errorCode ?? 0): \(String(describing: expected), privacy: .public)")
        } else {
            let elapsed = ProcessInfo.processInfo.systemUptime - sent
            Self.logger.debug("Reply in \(elapsed) s: \(String(describing: expected), privacy: .public)")
        }
        return reply
    }

    /// Called on the HID queue. Replies wake the waiting request; everything else goes to the session queue.
    private func receive(_ data: Data) {
        guard let packet = HIDPPPacket.parse(data) else { return }
        let request = pendingLock.withLock { () -> PendingRequest? in
            guard let pending, Self.packet(packet, answers: pending.expected) else { return nil }
            pending.reply = packet
            return pending
        }
        if let request {
            request.replied.signal()
        } else {
            queue.async { [weak self] in self?.handleNotification(packet) }
        }
    }

    private static func packet(_ packet: HIDPPPacket, answers expected: ExpectedReply) -> Bool {
        switch expected {
        case let .feature(deviceIndex, featureIndex, function):
            guard packet.deviceIndex == deviceIndex else { return false }
            if packet.isError { return packet.parameters.first.map { $0 & 0x0F == HIDPPPacket.softwareID } == true }
            return packet.featureIndex == featureIndex && packet.softwareID == HIDPPPacket.softwareID
                && (packet.function == function || packet.function == (function + 1) & 0x0F)
        case let .receiverRegister(command, address):
            return packet.deviceIndex == Receiver.index && packet.featureIndex == command
                && packet.function << 4 | packet.softwareID == address
        }
    }

    // MARK: Notifications

    private func handleNotification(_ packet: HIDPPPacket) {
        guard started else { return }
        if packet.deviceIndex == deviceIndex, packet.isDeviceConnectionNotification {
            if packet.reportsEstablishedLink {
                Self.logger.notice("Mouse woke")
                asleep = false
                scheduleRecovery()
            } else {
                Self.logger.notice("Mouse asleep")
                asleep = true
                cancelThumbScroll()
                onEvent?(.asleep)
            }
        } else if let battery, batterySupportsPercentage,
                  Battery.isNotification(packet, deviceIndex: deviceIndex, featureIndex: battery.index) {
            onEvent?(.battery(Battery.percent(from: packet.parameters, feature: battery.feature)))
        } else if activeMode, let thumbWheelIndex,
                  let report = ThumbWheelReport(packet: packet, deviceIndex: deviceIndex, featureIndex: thumbWheelIndex) {
            handleThumbWheel(report)
        } else if activeMode, packet.deviceIndex == deviceIndex, packet.featureIndex == controlsIndex,
                  packet.softwareID == 0 { // an event from the mouse, not a reply to another HID++ client
            if packet.function == 1 { handlePanelMotion(packet.parameters) }
            if packet.function == 0 { handleHeldControls(packet.parameters) }
        }
    }

    private func handleThumbWheel(_ report: ThumbWheelReport) {
        thumbScroll.consume(report)
        thumbIdleGeneration += 1
        let generation = thumbIdleGeneration
        // Close the gesture if the release report is lost, as it is when the link drops mid-scroll.
        guard thumbScroll.isActive else { return }
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, thumbIdleGeneration == generation else { return }
            thumbScroll.finish()
        }
    }

    private func handlePanelMotion(_ parameters: [UInt8]) {
        guard panelHeld, parameters.count >= 4 else { return }
        let dx = signed16(parameters[0], parameters[1]), dy = signed16(parameters[2], parameters[3])
        guard dx != 0 || dy != 0, let update = recognizer.ingest(dx: dx, dy: dy) else { return }
        output(update.phase == .began ? .began(axis: update.axis, delta: update.delta) : .changed(delta: update.delta))
    }

    /// A list of the control IDs held down, zero-terminated.
    private func handleHeldControls(_ parameters: [UInt8]) {
        let held = stride(from: 0, to: parameters.count - 1, by: 2)
            .map { unsigned16(parameters[$0], parameters[$0 + 1]) }
            .prefix { $0 != 0 }
            .contains(SensePanel.controlID)
        if held, !panelHeld {
            panelHeld = true
            recognizer.begin()
        } else if !held, panelHeld {
            panelHeld = false
            let end = recognizer.end()
            if end.didBeginSwipe {
                output(.ended)
            } else if end.isTap {
                outputQueue.async { [dockSwipe] in dockSwipe.tap() }
            }
        }
    }

    private func output(_ event: PanelGestureEvent) {
        outputQueue.async { [dockSwipe] in dockSwipe.handle(event) }
    }

    private func cancelGesture() {
        panelHeld = false
        recognizer.cancel()
        outputQueue.async { [dockSwipe] in dockSwipe.cancel() }
    }

    private func cancelThumbScroll() {
        thumbIdleGeneration += 1
        thumbScroll.finish(cancelled: true)
    }
}
