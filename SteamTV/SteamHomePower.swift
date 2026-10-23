import Foundation
import HomeKit

/// Powers the configured PC switch only. No lighting or power-off commands.
@MainActor
final class SteamHomePower: NSObject, HMHomeManagerDelegate {
    private var manager: HMHomeManager?
    private var ready = false
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor [weak self] in self?.ready = true }
    }
    func turnOn(named name: String) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if manager == nil {
            let manager = HMHomeManager(); manager.delegate = self; self.manager = manager
        }
        for _ in 0..<150 {
            if ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard let manager, ready else { throw PowerError("Apple Home did not finish loading. Try again.") }
        guard manager.authorizationStatus.contains(.authorized) else { throw PowerError("Allow Steam Remote Play to access Apple Home in Settings.") }
        let candidates = manager.homes.flatMap(\.accessories).flatMap { accessory in
            accessory.services.filter { $0.serviceType == HMServiceTypeOutlet || $0.serviceType == HMServiceTypeSwitch }
                .filter { $0.name.caseInsensitiveCompare(name) == .orderedSame || accessory.name.caseInsensitiveCompare(name) == .orderedSame }
                .map { (accessory, $0) }
        }
        guard candidates.count == 1, let (accessory, service) = candidates.first else {
            throw PowerError(candidates.isEmpty ? "Apple Home switch ‘\(name)’ was not found. Choose its name in Settings." : "More than one Apple Home switch matches ‘\(name)’. Give the PC switch a unique name.")
        }
        guard accessory.isReachable else { throw PowerError("Apple Home switch ‘\(name)’ is unreachable.") }
        guard let power = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypePowerState }) else { throw PowerError("This Apple Home accessory has no power control.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            power.writeValue(true) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    private struct PowerError: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }
}
