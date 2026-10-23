import Foundation
import GameController
import OSLog

enum ControllerExitGesture {
    static let holdDuration: TimeInterval = 0.55
    private static let logger = Logger(subsystem: "CloudNow", category: "ControllerExit")

    static func isStartSelectHeld(start: Bool, select: Bool) -> Bool {
        start && select
    }

    static func isStartSelectHeld(
        controller: GCController,
        logicalStart: Bool,
        logicalSelect: Bool
    ) -> Bool {
        let physicalStart = hasPressedPhysicalButton(
            controller: controller,
            matchingAny: ["start", "menu", "plus", "+"]
        )
        let physicalSelect = hasPressedPhysicalButton(
            controller: controller,
            matchingAny: ["select", "options", "back", "minus", "-", "share", "view"]
        )
        return (logicalStart || physicalStart) && (logicalSelect || physicalSelect)
    }

    static func updateHold(
        isPressed: Bool,
        heldSince: inout Date?,
        didTrigger: inout Bool,
        onExit: () -> Void
    ) {
        if isPressed {
            if heldSince == nil {
                heldSince = Date()
                didTrigger = false
            } else if !didTrigger,
                      let start = heldSince,
                      Date().timeIntervalSince(start) >= holdDuration {
                didTrigger = true
                onExit()
            }
        } else {
            heldSince = nil
            didTrigger = false
        }
    }

    @MainActor
    static func monitorStartSelectHold(onExit: @MainActor @escaping () -> Void) async {
        var heldSince: Date?
        var didTrigger = false
        var lastSummary = ""

        while !Task.isCancelled {
            let state = startSelectState()

            if state.pressed {
                if heldSince == nil {
                    heldSince = Date()
                    didTrigger = false
                    lastSummary = state.summary
                    logger.info("Controller Start+Select hold began: \(state.summary, privacy: .public)")
                } else if !didTrigger,
                          let start = heldSince,
                          Date().timeIntervalSince(start) >= holdDuration {
                    didTrigger = true
                    logger.info("Controller Start+Select hold triggered exit: \(lastSummary, privacy: .public)")
                    onExit()
                }
            } else {
                heldSince = nil
                didTrigger = false
            }

            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    private static func startSelectState() -> (pressed: Bool, summary: String) {
        for (index, controller) in GCController.controllers().enumerated() {
            guard let gamepad = controller.extendedGamepad else { continue }
            let startSources = startSources(for: controller, gamepad: gamepad)
            let selectSources = selectSources(for: controller, gamepad: gamepad)
            if !startSources.isEmpty && !selectSources.isEmpty {
                let vendor = controller.vendorName ?? "unknown"
                return (
                    true,
                    "#\(index + 1) \(vendor) start=\(startSources.joined(separator: "+")) select=\(selectSources.joined(separator: "+"))"
                )
            }
        }
        return (false, "")
    }

    @MainActor
    private static func startSources(for controller: GCController, gamepad: GCExtendedGamepad) -> [String] {
        var sources: [String] = []
        if gamepad.buttonMenu.isPressed { sources.append("menu") }
        sources.append(contentsOf: pressedPhysicalButtonNames(
            for: controller,
            matchingAny: ["start", "menu", "plus", "+"]
        ))
        return Array(Set(sources)).sorted()
    }

    @MainActor
    private static func selectSources(for controller: GCController, gamepad: GCExtendedGamepad) -> [String] {
        var sources: [String] = []
        if gamepad.buttonOptions?.isPressed == true { sources.append("options") }
        if gamepad.buttonHome?.isPressed == true { sources.append("home") }
        sources.append(contentsOf: pressedPhysicalButtonNames(
            for: controller,
            matchingAny: ["select", "options", "back", "minus", "-", "share", "view"]
        ))
        return Array(Set(sources)).sorted()
    }

    @MainActor
    private static func pressedPhysicalButtonNames(
        for controller: GCController,
        matchingAny needles: [String]
    ) -> [String] {
        controller.physicalInputProfile.buttons.compactMap { name, button in
            let lowercasedName = name.lowercased()
            guard button.isPressed,
                  needles.contains(where: { lowercasedName.contains($0) }) else { return nil }
            return name
        }
    }

    private static func hasPressedPhysicalButton(
        controller: GCController,
        matchingAny needles: [String]
    ) -> Bool {
        controller.physicalInputProfile.buttons.contains { name, button in
            let lowercasedName = name.lowercased()
            return button.isPressed && needles.contains { lowercasedName.contains($0) }
        }
    }
}

enum LaunchScreenControllerInput {
    /// Polls button state instead of replacing GameController handlers owned by
    /// the streaming input senders. A press must begin after the screen appears,
    /// preventing a held gameplay button from activating a newly shown error.
    @MainActor
    static func monitor(
        onConfirm: @MainActor @escaping () -> Void,
        onCancel: @MainActor @escaping () -> Void
    ) async {
        var previousConfirm = isConfirmPressed
        var previousCancel = isCancelPressed

        while !Task.isCancelled {
            let confirm = isConfirmPressed
            let cancel = isCancelPressed
            if cancel && !previousCancel {
                onCancel()
            } else if confirm && !previousConfirm {
                onConfirm()
            }
            previousConfirm = confirm
            previousCancel = cancel
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor
    private static var isConfirmPressed: Bool {
        GCController.controllers().contains { controller in
            guard let gamepad = controller.extendedGamepad else { return false }
            return gamepad.buttonA.isPressed
                || controller.physicalInputProfile.buttons.contains { name, button in
                    button.isPressed && ["a", "cross"].contains(name.lowercased())
                }
        }
    }

    @MainActor
    private static var isCancelPressed: Bool {
        GCController.controllers().contains { controller in
            guard let gamepad = controller.extendedGamepad else { return false }
            return gamepad.buttonB.isPressed
                || controller.physicalInputProfile.buttons.contains { name, button in
                    button.isPressed && ["b", "circle"].contains(name.lowercased())
                }
        }
    }
}
