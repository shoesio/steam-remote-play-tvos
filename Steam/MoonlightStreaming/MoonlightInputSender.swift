import Foundation
import GameController
import OSLog

final class MoonlightInputSender {
    private static let remoteSensitivity: Float = 250.0
    private static let remoteShortPressPulseTicks = 2

    private enum MoonlightButton {
        static let dpadUp = 0x0001
        static let dpadDown = 0x0002
        static let dpadLeft = 0x0004
        static let dpadRight = 0x0008
        static let start = 0x0010
        static let back = 0x0020
        static let leftStick = 0x0040
        static let rightStick = 0x0080
        static let leftShoulder = 0x0100
        static let rightShoulder = 0x0200
        static let guide = 0x0400
        static let a = 0x1000
        static let b = 0x2000
        static let x = 0x4000
        static let y = 0x8000
        static let misc = 0x200000
    }

    private enum ControllerType {
        static let xbox = 0x01
        static let playStation = 0x02
        static let nintendo = 0x03
    }

    private enum ControllerCapability {
        static let analogTriggers = 0x01
        static let rumble = 0x02
        static let triggerRumble = 0x04
        static let touchpad = 0x08
        static let accelerometer = 0x10
        static let gyro = 0x20
        static let batteryState = 0x40
        static let rgbLed = 0x80
    }

    var deadzone: Float = 0.15
    var onStatus: ((String) -> Void)?
    var exitComboHandler: (() -> Void)?

    private let logger = Logger(subsystem: "CloudNow", category: "MoonlightInput")
    private let bridge: CNMoonlightStreamBridge
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var activeGamepadMask = 0
    private var reportedFirstPacket = false
    private var reportedFirstMousePacket = false
    private var lastInputSummaries: [Int: String] = [:]
    private var lastReportedError: Int?
    private var lastReportedMouseError: Int?
    private var lastRemotePosition: (x: Float, y: Float) = (0, 0)
    private var remoteDirectionalButtons: UInt16 = 0
    private var remoteUIKitDirectionalButtons: UInt16 = 0
    private var remoteUIKitSelectPressed = false
    private var remoteUIKitBackPressed = false
    private var remoteUIKitSteamPressed = false
    private var remoteBackPulseTicks = 0
    private var remoteSteamPulseTicks = 0
    private var remoteSelectPulseTicks = 0
    private var remoteGamepadAnnounced = false
    private var exitComboHeldSince: Date?
    private var didTriggerExitCombo = false
    private var lastPhysicalButtonSummaryByController: [Int: String] = [:]
    private var lastPhysicalButtonLogDateByController: [Int: Date] = [:]
    private var lastImportantButtonMaskByController: [Int: UInt32] = [:]
    private var lastInputLogDateByController: [Int: Date] = [:]
    private var startHeldSinceByController: [ObjectIdentifier: Date] = [:]
    private var longStartHomeByController: Set<ObjectIdentifier> = []
    private var pendingStartPulseTicksByController: [ObjectIdentifier: Int] = [:]
    private var pendingGuidePulseTicksByController: [ObjectIdentifier: Int] = [:]
    private var selectHeldSinceByController: [ObjectIdentifier: Date] = [:]
    private var longSelectQuickAccessByController: Set<ObjectIdentifier> = []
    private var pendingBackPulseTicksByController: [ObjectIdentifier: Int] = [:]
    private var motionTimers: [String: Timer] = [:]
    private var lastKeyboardButtonSummary = ""

    init(bridge: CNMoonlightStreamBridge) {
        self.bridge = bridge
    }

    func start() {
        bridge.motionEventStateHandler = { [weak self] controllerNumber, motionType, reportRateHz in
            self?.setMotionEventState(
                controllerNumber: controllerNumber,
                motionType: motionType,
                reportRateHz: reportRateHz
            )
        }
        registerControllerNotifications()
        report(controllerInventoryDescription(prefix: "Controller inventory"))
        announceConnectedControllers()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        report("Controller input ready: \(controllerCountDescription())")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastRemotePosition = (0, 0)
        resetRemotePressState()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        startHeldSinceByController.removeAll()
        longStartHomeByController.removeAll()
        pendingStartPulseTicksByController.removeAll()
        pendingGuidePulseTicksByController.removeAll()
        selectHeldSinceByController.removeAll()
        longSelectQuickAccessByController.removeAll()
        pendingBackPulseTicksByController.removeAll()
        stopAllMotionReports()
        bridge.motionEventStateHandler = nil
        releaseSystemGestureClaims()
    }

    private func registerControllerNotifications() {
        let connectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            self?.controllerConnected(controller)
        }

        let disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            self?.controllerDisconnected(controller)
        }

        observers = [connectObserver, disconnectObserver]
        GCController.startWirelessControllerDiscovery()
    }

    private func announceConnectedControllers() {
        for (index, controller) in extendedControllers().enumerated() {
            activeGamepadMask |= 1 << index
            claimSystemGestures(controller)
            sendArrival(for: controller, index: index)
        }

        if activeGamepadMask == 0, siriRemote() != nil {
            announceRemoteGamepad()
        } else if activeGamepadMask == 0 {
            report("Waiting for a game controller")
        }
    }

    private func tick() {
        reportKeyboardInputIfNeeded()
        let remoteButtons = sendSiriRemoteInput()

        let controllers = extendedControllers()
        guard !controllers.isEmpty else {
            guard siriRemote() != nil else {
                disconnectRemoteGamepad()
                activeGamepadMask = 0
                return
            }

            if !remoteGamepadAnnounced {
                announceRemoteGamepad()
            }
            activeGamepadMask = 1
            let result = bridge.sendControllerState(
                with: 0,
                activeGamepadMask: activeGamepadMask,
                buttonFlags: Int(remoteButtons),
                leftTrigger: 0,
                rightTrigger: 0,
                leftStickX: 0,
                leftStickY: 0,
                rightStickX: 0,
                rightStickY: 0
            )
            reportPacketResultIfNeeded(
                result,
                state: (UInt32(remoteButtons), 0, 0, 0, 0, 0, 0),
                index: 0
            )
            return
        }

        if remoteGamepadAnnounced {
            disconnectRemoteGamepad()
        }

        var mask = 0
        for (index, controller) in controllers.enumerated() {
            mask |= 1 << index
            let physicalState = mapControllerToMoonlightInput(controller, deadzone: deadzone)
            // The Siri Remote and controller 1 intentionally share Sunshine's
            // slot 0. This keeps a single logical controller in Steam while
            // allowing either device to navigate and select at any time.
            let state = (
                buttons: physicalState.buttons | UInt32(index == 0
                    ? remoteButtonsForPrimaryController(remoteButtons, controller: controller)
                    : 0),
                leftTrigger: physicalState.leftTrigger,
                rightTrigger: physicalState.rightTrigger,
                lx: physicalState.lx,
                ly: physicalState.ly,
                rx: physicalState.rx,
                ry: physicalState.ry
            )
            reportPhysicalButtonChangeIfNeeded(controller: controller, index: index)
            updateExitCombo(controller: controller, state: state)
            reportInputChangeIfNeeded(state: state, index: index, source: controller.vendorName ?? "extended")
            let result = bridge.sendControllerState(
                with: index,
                activeGamepadMask: mask,
                buttonFlags: Int(state.buttons),
                leftTrigger: Int(state.leftTrigger),
                rightTrigger: Int(state.rightTrigger),
                leftStickX: Int(state.lx),
                leftStickY: Int(state.ly),
                rightStickX: Int(state.rx),
                rightStickY: Int(state.ry)
            )
            reportPacketResultIfNeeded(result, state: state, index: index)
        }
        activeGamepadMask = mask
    }

    private func remoteButtonsForPrimaryController(
        _ buttons: UInt16,
        controller _: GCController
    ) -> UInt16 {
        // The shared Sunshine slot is always announced as an Xbox controller.
        // Keep the Siri Remote in those same logical positions too: centre is
        // A/confirm and Back is B/cancel. Applying Nintendo compensation here
        // turns the remote's Back button into A after the physical face-button
        // mapping has already been corrected.
        buttons
    }

    private func sendSiriRemoteInput() -> UInt16 {
        guard let gamepad = siriRemote()?.microGamepad else {
            releaseRemoteMouseButtons()
            lastRemotePosition = (0, 0)
            resetRemotePressState()
            return 0
        }

        let currentX = gamepad.dpad.xAxis.value
        let currentY = gamepad.dpad.yAxis.value
        let isTouching = abs(currentX) > 0.02 || abs(currentY) > 0.02
        let wasTouching = abs(lastRemotePosition.x) > 0.02 || abs(lastRemotePosition.y) > 0.02
        let deltaX = currentX - lastRemotePosition.x
        let deltaY = currentY - lastRemotePosition.y
        lastRemotePosition = (currentX, currentY)

        if isTouching && wasTouching && (abs(deltaX) > 0.0005 || abs(deltaY) > 0.0005) {
            let mouseX = Int((deltaX * Self.remoteSensitivity).rounded())
            let mouseY = Int((-deltaY * Self.remoteSensitivity).rounded())
            reportMouseResultIfNeeded(bridge.sendMouseMove(deltaX: mouseX, deltaY: mouseY))
        }

        if remoteSelectPulseTicks > 0 {
            remoteSelectPulseTicks -= 1
        }
        if remoteBackPulseTicks > 0 {
            remoteBackPulseTicks -= 1
        }
        if remoteSteamPulseTicks > 0 {
            remoteSteamPulseTicks -= 1
        }

        let microGamepadSelectPressed = gamepad.buttonA.isPressed

        // UIKit's press events are authoritative for the Siri Remote. A centre
        // Select press can retain a stale touch position on the clickpad, so do
        // not reinterpret it as a direction based on the micro-gamepad axes.
        // Edge clicks arrive through the explicit direction handlers below.
        if remoteUIKitDirectionalButtons != 0 {
            remoteDirectionalButtons = remoteUIKitDirectionalButtons
        } else if microGamepadSelectPressed && !remoteUIKitSelectPressed {
            remoteDirectionalButtons = remoteDirections(for: gamepad)
        } else {
            remoteDirectionalButtons = 0
        }

        if remoteDirectionalButtons != 0 {
            return remoteDirectionalButtons
        }
        if remoteUIKitSteamPressed || remoteSteamPulseTicks > 0 {
            return UInt16(MoonlightButton.guide)
        }
        if remoteUIKitBackPressed || remoteBackPulseTicks > 0 || gamepad.buttonX.isPressed {
            return UInt16(MoonlightButton.b)
        }
        if remoteUIKitSelectPressed || remoteSelectPulseTicks > 0 || microGamepadSelectPressed {
            return UInt16(MoonlightButton.a)
        }
        return 0
    }

    private func remoteDirections(for gamepad: GCMicroGamepad) -> UInt16 {
        let x = gamepad.dpad.xAxis.value
        let y = gamepad.dpad.yAxis.value
        let directionalThreshold: Float = 0.5

        // The physical ring is cardinal, but the touch surface can report both
        // axes near a boundary. Pick one dominant direction so Steam receives a
        // clean D-pad event instead of a diagonal or an accidental A press.
        if abs(x) >= abs(y), abs(x) >= directionalThreshold {
            return UInt16(x < 0 ? MoonlightButton.dpadLeft : MoonlightButton.dpadRight)
        }
        if abs(y) >= directionalThreshold {
            return UInt16(y < 0 ? MoonlightButton.dpadDown : MoonlightButton.dpadUp)
        }
        return 0
    }

    func setRemoteDirection(_ direction: Int, pressed: Bool) {
        let button: UInt16
        switch direction {
        case 1: button = UInt16(MoonlightButton.dpadUp)
        case 2: button = UInt16(MoonlightButton.dpadDown)
        case 3: button = UInt16(MoonlightButton.dpadLeft)
        case 4: button = UInt16(MoonlightButton.dpadRight)
        default: return
        }

        if pressed {
            remoteUIKitDirectionalButtons |= button
            remoteDirectionalButtons = remoteUIKitDirectionalButtons
        } else {
            remoteUIKitDirectionalButtons &= ~button
            remoteDirectionalButtons &= ~button
        }
    }

    func setRemoteSelectPressed(_ pressed: Bool) {
        if !pressed && remoteUIKitSelectPressed {
            // Guarantee even a very quick centre click appears in at least one
            // 60 Hz Moonlight controller packet.
            remoteSelectPulseTicks = Self.remoteShortPressPulseTicks
        }
        remoteUIKitSelectPressed = pressed
    }

    func setRemoteBackPressed(_ pressed: Bool) {
        if !pressed && remoteUIKitBackPressed {
            // Guarantee a visible B pulse even if tvOS delivers Play/Pause
            // wholly between two of our 60 Hz input frames.
            remoteBackPulseTicks = Self.remoteShortPressPulseTicks
        }
        remoteUIKitBackPressed = pressed
    }

    func setRemoteSteamPressed(_ pressed: Bool) {
        if !pressed && remoteUIKitSteamPressed {
            remoteSteamPulseTicks = Self.remoteShortPressPulseTicks
        }
        remoteUIKitSteamPressed = pressed
    }

    private func siriRemote() -> GCController? {
        GCController.controllers().first {
            $0.extendedGamepad == nil && $0.microGamepad != nil
        }
    }

    private func announceRemoteGamepad() {
        guard !remoteGamepadAnnounced, extendedControllers().isEmpty, siriRemote() != nil else { return }
        activeGamepadMask = 1
        let supportedButtons = MoonlightButton.dpadUp |
            MoonlightButton.dpadDown |
            MoonlightButton.dpadLeft |
            MoonlightButton.dpadRight |
            MoonlightButton.a |
            MoonlightButton.b
        let result = bridge.sendControllerArrival(
            with: 0,
            activeGamepadMask: activeGamepadMask,
            type: ControllerType.xbox,
            supportedButtonFlags: supportedButtons,
            capabilities: 0
        )
        remoteGamepadAnnounced = result == 0
        if remoteGamepadAnnounced {
            report("Siri Remote navigation is available to Steam")
        } else {
            report("Siri Remote gamepad announcement failed: \(result)")
        }
    }

    private func disconnectRemoteGamepad() {
        guard remoteGamepadAnnounced else { return }
        _ = bridge.sendControllerDisconnect(with: 0, activeGamepadMask: 0)
        remoteGamepadAnnounced = false
        activeGamepadMask = 0
    }

    private func releaseRemoteMouseButtons() {
        // Centre Select is controller A/Confirm. No mouse buttons are held by
        // the Siri Remote input path.
    }

    private func resetRemotePressState() {
        remoteDirectionalButtons = 0
        remoteUIKitDirectionalButtons = 0
        remoteUIKitSelectPressed = false
        remoteUIKitBackPressed = false
        remoteUIKitSteamPressed = false
        remoteBackPulseTicks = 0
        remoteSteamPulseTicks = 0
        remoteSelectPulseTicks = 0
    }

    private func updateExitCombo(
        controller: GCController,
        state: (buttons: UInt32, leftTrigger: UInt8, rightTrigger: UInt8, lx: Int16, ly: Int16, rx: Int16, ry: Int16)
    ) {
        ControllerExitGesture.updateHold(
            isPressed: ControllerExitGesture.isStartSelectHeld(
                controller: controller,
                logicalStart: (state.buttons & UInt32(MoonlightButton.start)) != 0,
                logicalSelect: (state.buttons & UInt32(MoonlightButton.back)) != 0
            ),
            heldSince: &exitComboHeldSince,
            didTrigger: &didTriggerExitCombo
        ) { [weak self] in
            self?.report("Controller Start+Select hold requested Moonlight stream exit")
            self?.exitComboHandler?()
        }
    }

    private func reportMouseResultIfNeeded(_ result: Int) {
        if result != 0 {
            if lastReportedMouseError != result {
                lastReportedMouseError = result
                report("Mouse packet failed: \(result)")
            }
            return
        }

        lastReportedMouseError = nil
        guard !reportedFirstMousePacket else { return }
        reportedFirstMousePacket = true
        report("Siri Remote mouse input is being sent")
    }

    private func controllerConnected(_ controller: GCController) {
        if controller.extendedGamepad != nil {
            // The Siri Remote occupies slot 0 only while it is the sole input
            // device. Remove that virtual controller before a real controller
            // takes the slot.
            disconnectRemoteGamepad()
            let index = extendedControllers().firstIndex(where: { $0 === controller }) ?? 0
            activeGamepadMask = currentMask()
            claimSystemGestures(controller)
            sendArrival(for: controller, index: index)
            report("Controller connected")
        } else if controller.microGamepad != nil, extendedControllers().isEmpty {
            announceRemoteGamepad()
        }
        report(controllerInventoryDescription(prefix: "Controller inventory"))
    }

    private func controllerDisconnected(_ controller: GCController) {
        let controllerID = ObjectIdentifier(controller)
        startHeldSinceByController.removeValue(forKey: controllerID)
        longStartHomeByController.remove(controllerID)
        pendingStartPulseTicksByController.removeValue(forKey: controllerID)
        pendingGuidePulseTicksByController.removeValue(forKey: controllerID)
        selectHeldSinceByController.removeValue(forKey: controllerID)
        longSelectQuickAccessByController.remove(controllerID)
        pendingBackPulseTicksByController.removeValue(forKey: controllerID)

        if controller.extendedGamepad == nil {
            if siriRemote() == nil {
                releaseRemoteMouseButtons()
                resetRemotePressState()
                disconnectRemoteGamepad()
            }
            report(controllerInventoryDescription(prefix: "Controller inventory"))
            return
        }

        let oldIndex = max(0, min(15, activeGamepadMask.nonzeroBitCount - 1))
        activeGamepadMask = currentMask()
        let result = bridge.sendControllerDisconnect(with: oldIndex, activeGamepadMask: activeGamepadMask)
        if result != 0 {
            report("Controller disconnect failed: \(result)")
        }
        report("Controller disconnected")
        if activeGamepadMask == 0 {
            announceRemoteGamepad()
        }
        report(controllerInventoryDescription(prefix: "Controller inventory"))
    }

    private func sendArrival(for controller: GCController, index: Int) {
        let result = bridge.sendControllerArrival(
            with: index,
            activeGamepadMask: activeGamepadMask,
            type: controllerType(for: controller),
            supportedButtonFlags: supportedButtonFlags(for: controller),
            capabilities: capabilities(for: controller)
        )
        let vendor = controller.vendorName ?? "Game controller"
        report("Controller \(index + 1) announced: \(vendor) (\(result))")
    }

    private func currentMask() -> Int {
        var mask = 0
        for (index, _) in extendedControllers().enumerated() {
            mask |= 1 << index
        }
        return mask
    }

    private func extendedControllers() -> [GCController] {
        Array(GCController.controllers().filter { $0.extendedGamepad != nil }.prefix(16))
    }

    private func controllerCountDescription() -> String {
        let extended = extendedControllers().count
        let micro = GCController.controllers().filter { $0.extendedGamepad == nil && $0.microGamepad != nil }.count
        if extended > 0 {
            return "\(extended) extended detected"
        }
        if micro > 0 {
            return "0 extended detected (\(micro) micro ignored)"
        }
        return "0 detected"
    }

    private func controllerInventoryDescription(prefix: String) -> String {
        let controllers = GCController.controllers()
        let keyboardDescription = GCKeyboard.coalesced != nil ? ", keyboard/HID present" : ""
        guard !controllers.isEmpty else {
            return "\(prefix): none\(keyboardDescription)"
        }

        let descriptions = controllers.enumerated().map { index, controller in
            let vendor = controller.vendorName ?? "unknown"
            let profile: String
            if controller.extendedGamepad != nil {
                profile = "extended"
            } else if controller.microGamepad != nil {
                profile = "micro"
            } else {
                profile = "unknown"
            }
            let motion = controller.motion
            let motionDescription = "gyro=\(motion?.hasRotationRate == true) accel=\(motion?.hasGravityAndUserAcceleration == true)"
            return "#\(index + 1) \(vendor) [\(profile), \(motionDescription)]"
        }
        return "\(prefix): \(descriptions.joined(separator: ", "))\(keyboardDescription)"
    }

    private func reportKeyboardInputIfNeeded() {
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else {
            lastKeyboardButtonSummary = ""
            return
        }
        let pressed = keyboard.buttons.compactMap { name, button in
            button.isPressed ? name : nil
        }.sorted().joined(separator: "+")
        guard pressed != lastKeyboardButtonSummary else { return }
        lastKeyboardButtonSummary = pressed
        guard !pressed.isEmpty else { return }
        print("[MoonlightInput] Keyboard/HID buttons pressed: \(pressed)")
    }

    private func controllerType(for controller: GCController) -> Int {
        guard let pad = controller.extendedGamepad else { return ControllerType.xbox }
        if pad is GCDualSenseGamepad || pad is GCDualShockGamepad {
            return ControllerType.playStation
        }
        if isNintendoStyleController(controller) {
            return ControllerType.nintendo
        }
        return ControllerType.xbox
    }

    private func supportedButtonFlags(for controller: GCController) -> Int {
        guard let pad = controller.extendedGamepad else { return 0 }
        var flags = MoonlightButton.dpadUp | MoonlightButton.dpadDown | MoonlightButton.dpadLeft | MoonlightButton.dpadRight
        flags |= MoonlightButton.start
        if pad.buttonOptions != nil { flags |= MoonlightButton.back }
        flags |= MoonlightButton.leftShoulder | MoonlightButton.rightShoulder
        flags |= MoonlightButton.a | MoonlightButton.b | MoonlightButton.x | MoonlightButton.y
        if pad.leftThumbstickButton != nil { flags |= MoonlightButton.leftStick }
        if pad.rightThumbstickButton != nil { flags |= MoonlightButton.rightStick }
        if pad.buttonHome != nil { flags |= MoonlightButton.guide }
        return flags
    }

    private func capabilities(for controller: GCController) -> Int {
        guard let pad = controller.extendedGamepad else { return 0 }
        var capabilities = ControllerCapability.analogTriggers
        if pad is GCDualSenseGamepad || pad is GCDualShockGamepad {
            capabilities |= ControllerCapability.touchpad
        }
        if controller.motion?.hasRotationRate == true {
            capabilities |= ControllerCapability.gyro
        }
        if controller.motion?.hasGravityAndUserAcceleration == true {
            capabilities |= ControllerCapability.accelerometer
        }
        return capabilities
    }

    private func setMotionEventState(
        controllerNumber: Int,
        motionType: Int,
        reportRateHz: Int
    ) {
        let key = "\(controllerNumber):\(motionType)"
        motionTimers[key]?.invalidate()
        motionTimers.removeValue(forKey: key)

        guard reportRateHz > 0,
              extendedControllers().indices.contains(controllerNumber),
              let motion = extendedControllers()[controllerNumber].motion else {
            updateMotionSensorActivation()
            return
        }

        let supported = motionType == 1
            ? motion.hasGravityAndUserAcceleration
            : motionType == 2 && motion.hasRotationRate
        guard supported else {
            report("Controller \(controllerNumber + 1) motion type \(motionType) unavailable")
            updateMotionSensorActivation()
            return
        }

        let interval = 1.0 / Double(max(1, min(reportRateHz, 120)))
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self, weak controller = extendedControllers()[controllerNumber]] _ in
            guard let self, let motion = controller?.motion else { return }
            let result: Int
            if motionType == 1 {
                let sample = motion.acceleration
                result = self.bridge.sendControllerMotion(
                    with: controllerNumber,
                    motionType: motionType,
                    x: Float(sample.x * -9.80665),
                    y: Float(sample.y * -9.80665),
                    z: Float(sample.z * -9.80665)
                )
            } else {
                let sample = motion.rotationRate
                result = self.bridge.sendControllerMotion(
                    with: controllerNumber,
                    motionType: motionType,
                    x: Float(sample.x * 57.2957795),
                    y: Float(sample.z * 57.2957795),
                    z: Float(sample.y * -57.2957795)
                )
            }
            if result != 0 {
                self.report("Controller motion packet failed: \(result)")
            }
        }
        motionTimers[key] = timer
        updateMotionSensorActivation()
        report("Controller \(controllerNumber + 1) motion enabled at \(reportRateHz) Hz")
    }

    private func stopAllMotionReports() {
        for timer in motionTimers.values {
            timer.invalidate()
        }
        motionTimers.removeAll()
        updateMotionSensorActivation()
    }

    private func updateMotionSensorActivation() {
        for controller in extendedControllers() {
            guard let motion = controller.motion, motion.sensorsRequireManualActivation else { continue }
            motion.sensorsActive = !motionTimers.isEmpty
        }
    }

    private func mapControllerToMoonlightInput(
        _ controller: GCController,
        deadzone: Float
    ) -> (buttons: UInt32, leftTrigger: UInt8, rightTrigger: UInt8, lx: Int16, ly: Int16, rx: Int16, ry: Int16) {
        guard let pad = controller.extendedGamepad else {
            return (0, 0, 0, 0, 0, 0, 0)
        }

        var buttons = 0
        func pressed(_ input: GCControllerButtonInput) -> Bool { input.isPressed }
        func add(_ mask: Int, when condition: Bool) {
            if condition { buttons |= mask }
        }

        add(MoonlightButton.dpadUp, when: pressed(pad.dpad.up))
        add(MoonlightButton.dpadDown, when: pressed(pad.dpad.down))
        add(MoonlightButton.dpadLeft, when: pressed(pad.dpad.left))
        add(MoonlightButton.dpadRight, when: pressed(pad.dpad.right))
        let longStartIsHome = true
        if let options = pad.buttonOptions {
            let controllerID = ObjectIdentifier(controller)
            // The Xbox-mode GuliKit profile exposes its two centre controls in
            // the opposite GameController slots. A real Nintendo profile does
            // not: Minus is Options/Select and Plus is Menu/Start.
            let usesSwappedCentreLayout = isGuliKitController(controller) &&
                !isNintendoStyleController(controller)
            // GuliKit's tvOS profile exposes the user's Start control as the
            // physical minus/Options input. For that controller, swap only the
            // two centre controls before applying the hold gesture. Other
            // profiles continue to use Menu. When Options exists, do not also
            // accept buttonHome: Nintendo profiles can alias Minus to both,
            // which incorrectly turns Select into the Steam Home button.
            let startIsPressed = usesSwappedCentreLayout
                ? pressed(options)
                : pressed(pad.buttonMenu)

            if longStartIsHome {
                if startIsPressed {
                    let heldSince = startHeldSinceByController[controllerID] ?? Date()
                    startHeldSinceByController[controllerID] = heldSince
                    if Date().timeIntervalSince(heldSince) >= 0.75,
                       !longStartHomeByController.contains(controllerID) {
                        longStartHomeByController.insert(controllerID)
                        if !usesSwappedCentreLayout {
                            let result = bridge.sendSteamQuickAccessShortcut()
                            if result != 0 {
                                report("Steam Quick Access shortcut failed: \(result)")
                            } else {
                                report("Controller long Plus opened Steam Quick Access")
                            }
                        }
                    }
                } else if startHeldSinceByController.removeValue(forKey: controllerID) != nil {
                    if longStartHomeByController.remove(controllerID) != nil {
                        if usesSwappedCentreLayout {
                            pendingGuidePulseTicksByController[controllerID] = 2
                            report("Controller long Minus opened Steam Home")
                        }
                    } else {
                        pendingStartPulseTicksByController[controllerID] = 2
                    }
                }

                if let ticks = pendingGuidePulseTicksByController[controllerID], ticks > 0 {
                    add(MoonlightButton.guide, when: true)
                    if ticks == 1 {
                        pendingGuidePulseTicksByController.removeValue(forKey: controllerID)
                    } else {
                        pendingGuidePulseTicksByController[controllerID] = ticks - 1
                    }
                }

                if let ticks = pendingStartPulseTicksByController[controllerID], ticks > 0 {
                    add(MoonlightButton.start, when: true)
                    if ticks == 1 {
                        pendingStartPulseTicksByController.removeValue(forKey: controllerID)
                    } else {
                        pendingStartPulseTicksByController[controllerID] = ticks - 1
                    }
                }
            } else {
                add(MoonlightButton.start, when: startIsPressed)
            }

            let selectIsPressed = usesSwappedCentreLayout
                ? pressed(pad.buttonMenu)
                : pressed(options)
            if selectIsPressed {
                let heldSince = selectHeldSinceByController[controllerID] ?? Date()
                selectHeldSinceByController[controllerID] = heldSince
                if Date().timeIntervalSince(heldSince) >= 0.75,
                   !longSelectQuickAccessByController.contains(controllerID) {
                    longSelectQuickAccessByController.insert(controllerID)
                    if usesSwappedCentreLayout {
                        let result = bridge.sendSteamQuickAccessShortcut()
                        if result != 0 {
                            report("Steam Quick Access shortcut failed: \(result)")
                        } else {
                            report("Controller long Plus opened Steam Quick Access")
                        }
                    }
                }
            } else if selectHeldSinceByController.removeValue(forKey: controllerID) != nil {
                if longSelectQuickAccessByController.remove(controllerID) != nil {
                    if !usesSwappedCentreLayout {
                        pendingGuidePulseTicksByController[controllerID] = 2
                        report("Controller long Minus opened Steam Home")
                    }
                } else {
                    pendingBackPulseTicksByController[controllerID] = 2
                }
            }

            if let ticks = pendingBackPulseTicksByController[controllerID], ticks > 0 {
                add(MoonlightButton.back, when: true)
                if ticks == 1 {
                    pendingBackPulseTicksByController.removeValue(forKey: controllerID)
                } else {
                    pendingBackPulseTicksByController[controllerID] = ticks - 1
                }
            }
        }
        // Some tvOS controller profiles alias Menu/Start to buttonHome. When
        // long-Start mapping is enabled, accepting both would emit Guide as
        // soon as Start is pressed and defeat the hold gesture.
        if !longStartIsHome, let home = pad.buttonHome {
            add(MoonlightButton.guide, when: pressed(home))
        }
        if let leftStick = pad.leftThumbstickButton {
            add(MoonlightButton.leftStick, when: pressed(leftStick))
        }
        if let rightStick = pad.rightThumbstickButton {
            add(MoonlightButton.rightStick, when: pressed(rightStick))
        }
        add(MoonlightButton.leftShoulder, when: pressed(pad.leftShoulder))
        add(MoonlightButton.rightShoulder, when: pressed(pad.rightShoulder))
        if let share = controller.physicalInputProfile.buttons[GCInputButtonShare] {
            add(MoonlightButton.misc, when: pressed(share))
        }

        // Sunshine exposes this slot as an Xbox controller. GameController's
        // logical face-button inputs already match the positions expected by
        // that layout, so do not apply an additional Nintendo-style swap.
        add(MoonlightButton.a, when: pressed(pad.buttonA))
        add(MoonlightButton.b, when: pressed(pad.buttonB))
        add(MoonlightButton.x, when: pressed(pad.buttonX))
        add(MoonlightButton.y, when: pressed(pad.buttonY))

        let lt = UInt8(clamping: Int(pad.leftTrigger.value * 255))
        let rt = UInt8(clamping: Int(pad.rightTrigger.value * 255))
        let (lx, ly) = radialDeadzone(x: pad.leftThumbstick.xAxis.value, y: pad.leftThumbstick.yAxis.value, deadzone: deadzone)
        let (rx, ry) = radialDeadzone(x: pad.rightThumbstick.xAxis.value, y: pad.rightThumbstick.yAxis.value, deadzone: deadzone)
        return (UInt32(buttons), lt, rt, lx, ly, rx, ry)
    }

    private func isNintendoStyleController(_ controller: GCController) -> Bool {
        let vendor = controller.vendorName ?? ""
        let explicitlyNintendo = vendor.localizedCaseInsensitiveContains("Nintendo") ||
            vendor.localizedCaseInsensitiveContains("Switch") ||
            vendor.localizedCaseInsensitiveContains("Pro Controller")
        if explicitlyNintendo {
            return true
        }

        // GuliKit pads retain their brand name in several transport modes.
        // Brand alone must not turn the Xbox-mode profile into a Nintendo
        // controller. Its Switch profile exposes the motion sensor as well.
        let isGuliKit = vendor.localizedCaseInsensitiveContains("Guli") ||
            vendor.localizedCaseInsensitiveContains("Gulikit") ||
            vendor.localizedCaseInsensitiveContains("KingKong")
        return isGuliKit && controller.motion?.hasRotationRate == true
    }

    private func isGuliKitController(_ controller: GCController) -> Bool {
        let vendor = controller.vendorName ?? ""
        return vendor.localizedCaseInsensitiveContains("Guli") ||
            vendor.localizedCaseInsensitiveContains("Gulikit") ||
            vendor.localizedCaseInsensitiveContains("KingKong")
    }

    private func reportPacketResultIfNeeded(
        _ result: Int,
        state: (buttons: UInt32, leftTrigger: UInt8, rightTrigger: UInt8, lx: Int16, ly: Int16, rx: Int16, ry: Int16),
        index: Int
    ) {
        if result != 0 {
            if lastReportedError != result {
                lastReportedError = result
                report("Controller packet failed: \(result)")
            }
            return
        }

        lastReportedError = nil
        guard !reportedFirstPacket else { return }
        let hasInput = state.buttons != 0 ||
            state.leftTrigger != 0 ||
            state.rightTrigger != 0 ||
            state.lx != 0 ||
            state.ly != 0 ||
            state.rx != 0 ||
            state.ry != 0
        if hasInput {
            reportedFirstPacket = true
            report("Controller \(index + 1) input is being sent")
        }
    }

    private func reportPhysicalButtonChangeIfNeeded(controller: GCController, index: Int) {
        let pressedNames = controller.physicalInputProfile.buttons.compactMap { name, button in
            button.isPressed ? name : nil
        }.sorted()
        let summary = pressedNames.joined(separator: "+")
        guard lastPhysicalButtonSummaryByController[index] != summary else { return }
        lastPhysicalButtonSummaryByController[index] = summary
        guard !summary.isEmpty else { return }

        let now = Date()
        if let lastLogDate = lastPhysicalButtonLogDateByController[index], now.timeIntervalSince(lastLogDate) < 1 {
            return
        }
        lastPhysicalButtonLogDateByController[index] = now
        logger.info("Controller \(index + 1, privacy: .public) physical buttons pressed: \(summary, privacy: .public)")
    }

    private func reportInputChangeIfNeeded(
        state: (buttons: UInt32, leftTrigger: UInt8, rightTrigger: UInt8, lx: Int16, ly: Int16, rx: Int16, ry: Int16),
        index: Int,
        source: String
    ) {
        let summary = String(
            format: "buttons=0x%04X lt=%03d rt=%03d ls=(%d,%d) rs=(%d,%d)",
            state.buttons,
            state.leftTrigger,
            state.rightTrigger,
            state.lx,
            state.ly,
            state.rx,
            state.ry
        )
        guard summary != lastInputSummaries[index] else { return }
        lastInputSummaries[index] = summary

        let importantButtons = state.buttons & UInt32(
            MoonlightButton.start |
            MoonlightButton.back |
            MoonlightButton.a |
            MoonlightButton.b |
            MoonlightButton.x |
            MoonlightButton.y
        )
        if importantButtons != lastImportantButtonMaskByController[index] && importantButtons != 0 {
            let names = buttonNames(for: state.buttons)
            let rawButtons = String(format: "0x%04X", state.buttons)
            logger.debug("Controller \(index + 1, privacy: .public) important buttons: \(names, privacy: .public) raw=\(rawButtons, privacy: .public) source=\(source, privacy: .public)")
        }
        lastImportantButtonMaskByController[index] = importantButtons

        let hasInput = state.buttons != 0 ||
            state.leftTrigger != 0 ||
            state.rightTrigger != 0 ||
            state.lx != 0 ||
            state.ly != 0 ||
            state.rx != 0 ||
            state.ry != 0
        guard hasInput else { return }

        let now = Date()
        if let lastLogDate = lastInputLogDateByController[index], now.timeIntervalSince(lastLogDate) < 1 {
            return
        }
        lastInputLogDateByController[index] = now
        logger.info("Controller \(index + 1, privacy: .public) input changed: \(summary, privacy: .public)")
        print("[MoonlightInput] Controller \(index + 1) input changed: \(summary)")
    }

    private func buttonNames(for buttons: UInt32) -> String {
        var names: [String] = []
        func add(_ mask: Int, _ name: String) {
            if buttons & UInt32(mask) != 0 {
                names.append(name)
            }
        }
        add(MoonlightButton.start, "start/menu")
        add(MoonlightButton.back, "back/options")
        add(MoonlightButton.a, "a")
        add(MoonlightButton.b, "b")
        add(MoonlightButton.x, "x")
        add(MoonlightButton.y, "y")
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }

    private func report(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[MoonlightInput] \(message)")
        onStatus?(message)
    }

    private func claimSystemGestures(_ controller: GCController) {
        guard controller.extendedGamepad != nil else { return }
        if controller.extendedGamepad?.buttonOptions == nil {
            controller.controllerPausedHandler = { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                DispatchQueue.main.async {
                    self.sendLegacyPausePulse(for: controller)
                }
            }
        }
        // Match Moonlight's tvOS implementation: remapped controllers can expose
        // physical elements that are not the same objects as extendedGamepad's
        // logical buttons. Claiming every physical element prevents tvOS from
        // translating a controller face button into UIPressTypeMenu.
        for element in controller.physicalInputProfile.allElements {
            element.preferredSystemGestureState = .disabled
        }
    }

    private func releaseSystemGestureClaims() {
        for controller in GCController.controllers() {
            guard controller.extendedGamepad != nil else { continue }
            controller.controllerPausedHandler = nil
            for element in controller.physicalInputProfile.allElements {
                element.preferredSystemGestureState = .enabled
            }
        }
    }

    private func sendLegacyPausePulse(for controller: GCController) {
        guard let index = extendedControllers().firstIndex(where: { $0 === controller }) else { return }
        report("Controller \(index + 1) legacy pause requested Moonlight stream exit")
        exitComboHandler?()
    }
}
