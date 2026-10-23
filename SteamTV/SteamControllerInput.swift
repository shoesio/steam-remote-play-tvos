import Foundation
import GameController

@MainActor
final class SteamControllerInput {
    private weak var session: SteamStreamingSession?
    private var task: Task<Void, Never>?
    private var controllers: [GCController] = []
    private var heldSince: [ObjectIdentifier: TimeInterval] = [:]
    private let exit: () -> Void
    init(exit: @escaping () -> Void) { self.exit = exit }
    func start(session: SteamStreamingSession) {
        stop(); self.session = session
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }
    func pause() { task?.cancel(); task = nil }
    func stop() {
        task?.cancel(); task = nil
        for controller in controllers {
            for element in controller.physicalInputProfile.allElements { element.preferredSystemGestureState = .enabled }
        }
        controllers = []; heldSince = [:]
        UserDefaults.standard.set(0, forKey: "SteamTV.controllerCount")
        session?.setControllerSlots([]); session = nil
    }
    private func poll() {
        let available = GCController.controllers().filter { $0.extendedGamepad != nil }
        let updated = Array((controllers.filter { controller in available.contains { $0 === controller } }
            + available.filter { controller in !controllers.contains { $0 === controller } }).prefix(4))
        if updated.map(ObjectIdentifier.init) != controllers.map(ObjectIdentifier.init) {
            for controller in controllers where !updated.contains(where: { $0 === controller }) {
                for element in controller.physicalInputProfile.allElements { element.preferredSystemGestureState = .enabled }
            }
            controllers = updated; heldSince = [:]
            UserDefaults.standard.set(controllers.count, forKey: "SteamTV.controllerCount")
            session?.setControllerSlots(Array(controllers.indices))
        }
        let deadzone = Float(SteamSharedSettings.defaults.double(forKey: "SteamTV.deadzone"))
        for (slot, controller) in controllers.enumerated() {
            guard let pad = controller.extendedGamepad else { continue }
            for element in controller.physicalInputProfile.allElements { element.preferredSystemGestureState = .disabled }
            let key = ObjectIdentifier(controller)
            let held = pad.buttonMenu.isPressed && pad.buttonOptions?.isPressed == true
            if held {
                let now = ProcessInfo.processInfo.systemUptime
                if heldSince[key] == nil { heldSince[key] = now }
                if now - (heldSince[key] ?? now) >= 0.55 {
                    // Neutralize input before ending the stream.
                    session?.sendGamepad(slot: slot, state: SteamGamepadState())
                    exit(); return
                }
            } else { heldSince[key] = nil }
            var buttons: UInt16 = 0
            let pressed: [Bool] = [pad.buttonA.isPressed, pad.buttonB.isPressed, pad.buttonX.isPressed, pad.buttonY.isPressed,
                pad.buttonOptions?.isPressed == true, pad.buttonHome?.isPressed == true && pad.buttonHome !== pad.buttonMenu && pad.buttonHome !== pad.buttonOptions, pad.buttonMenu.isPressed,
                pad.leftThumbstickButton?.isPressed == true, pad.rightThumbstickButton?.isPressed == true,
                pad.leftShoulder.isPressed, pad.rightShoulder.isPressed,
                pad.dpad.up.isPressed, pad.dpad.down.isPressed, pad.dpad.left.isPressed, pad.dpad.right.isPressed]
            for (bit, value) in pressed.enumerated() where value { buttons |= 1 << bit }
            let axes: [Int16] = [SteamGamepadState.axis(pad.leftThumbstick.xAxis.value, deadzone: deadzone),
                SteamGamepadState.axis(-pad.leftThumbstick.yAxis.value, deadzone: deadzone),
                SteamGamepadState.axis(pad.rightThumbstick.xAxis.value, deadzone: deadzone),
                SteamGamepadState.axis(-pad.rightThumbstick.yAxis.value, deadzone: deadzone),
                SteamGamepadState.axis(pad.leftTrigger.value, deadzone: 0),
                SteamGamepadState.axis(pad.rightTrigger.value, deadzone: 0)]
            session?.sendGamepad(slot: slot, state: SteamGamepadState(axes: axes, buttons: buttons))
        }
    }
}
