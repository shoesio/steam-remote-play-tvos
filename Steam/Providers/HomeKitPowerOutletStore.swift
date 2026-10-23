import Foundation
import HomeKit
import Observation

struct HomeKitPowerOutlet: Identifiable, Hashable {
    let id: String
    let name: String
    let serviceName: String
    let isOutletService: Bool
    let roomName: String?
    let isReachable: Bool
    let isOn: Bool?

    var displayName: String {
        let serviceLabel = serviceName.isEmpty || serviceName.localizedCaseInsensitiveCompare(name) == .orderedSame
            ? name
            : "\(name) · \(serviceName)"
        guard let roomName, !roomName.isEmpty else { return serviceLabel }
        return "\(serviceLabel) · \(roomName)"
    }
}

enum HomeKitPowerOutletError: LocalizedError {
    case accessUnavailable
    case homeDataTimedOut
    case outletNotFound
    case outletUnreachable(String)
    case missingPowerCharacteristic(String)
    case powerStateDidNotChange(String)

    var errorDescription: String? {
        switch self {
        case .accessUnavailable:
            return "Stream does not have permission to access Apple Home."
        case .homeDataTimedOut:
            return "Apple Home did not finish loading its accessories."
        case .outletNotFound:
            return "The selected Apple Home power outlet could not be found. Choose it again in Settings."
        case .outletUnreachable(let name):
            return "The Apple Home outlet “\(name)” is not reachable."
        case .missingPowerCharacteristic(let name):
            return "The Apple Home accessory “\(name)” does not expose an on/off control."
        case .powerStateDidNotChange(let name):
            return "Apple Home accepted the command, but “\(name)” did not turn off."
        }
    }
}

@MainActor
@Observable
final class HomeKitPowerOutletStore: NSObject, HMHomeManagerDelegate {
    private struct AmbientLightSnapshot {
        let serviceID: UUID
        let hue: Any?
        let saturation: Any?
        let brightness: Any?
        let power: Any?
    }
    static let shared = HomeKitPowerOutletStore()
    private static let selectionKey = "sunshine.homeKitPowerOutlet"

    private(set) var outlets: [HomeKitPowerOutlet] = []
    private(set) var hasStarted = false
    private(set) var isReady = false
    private(set) var authorizationStatus: HMHomeManagerAuthorizationStatus = []
    var selectedOutletID: String {
        didSet {
            UserDefaults.standard.set(selectedOutletID, forKey: Self.selectionKey)
        }
    }

    @ObservationIgnored private var homeManager: HMHomeManager?
    @ObservationIgnored private var preparedAmbientServices = Set<UUID>()
    @ObservationIgnored private var ambientLightSnapshot: AmbientLightSnapshot?
    @ObservationIgnored private var ambientWriteInProgress = false

    override init() {
        selectedOutletID = UserDefaults.standard.string(forKey: Self.selectionKey) ?? ""
        super.init()
    }

    var hasSelectedOutlet: Bool {
        !selectedOutletID.isEmpty
    }

    var selectedOutlet: HomeKitPowerOutlet? {
        outlets.first { $0.id == selectedOutletID }
    }

    func start() {
        guard homeManager == nil else {
            refreshOutlets()
            return
        }
        let manager = HMHomeManager()
        manager.delegate = self
        homeManager = manager
        hasStarted = true
        authorizationStatus = manager.authorizationStatus
    }

    func refresh() async {
        start()
        try? await waitUntilReady()
        refreshOutlets()
    }

    @discardableResult
    func selectOutlet(matching configuredName: String) -> Bool {
        let desired = configuredName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDesired = Self.normalizedName(desired)
        guard !desired.isEmpty else { return hasSelectedOutlet }
        let candidates = outlets.filter {
            $0.name.compare(desired, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                || $0.serviceName.compare(desired, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                || $0.displayName.localizedCaseInsensitiveContains(desired)
                || Self.normalizedName($0.name) == normalizedDesired
                || Self.normalizedName($0.serviceName) == normalizedDesired
                || Self.normalizedName($0.displayName).contains(normalizedDesired)
        }
        guard let match = candidates.sorted(by: { lhs, rhs in
            let lhsExactService = lhs.serviceName.compare(desired, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            let rhsExactService = rhs.serviceName.compare(desired, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            if lhsExactService != rhsExactService { return lhsExactService }
            if lhs.isOutletService != rhs.isOutletService { return lhs.isOutletService }
            if lhs.isReachable != rhs.isReachable { return lhs.isReachable }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }).first else {
            selectedOutletID = ""
            return false
        }
        selectedOutletID = match.id
        return true
    }

    func setSelectedOutletPower(_ enabled: Bool) async throws {
        guard hasSelectedOutlet else { return }
        start()
        try await waitUntilReady()
        guard authorizationStatus.contains(.authorized) else {
            throw HomeKitPowerOutletError.accessUnavailable
        }
        guard let target = liveOutlet(withID: selectedOutletID) else {
            throw HomeKitPowerOutletError.outletNotFound
        }
        guard target.accessory.isReachable else {
            throw HomeKitPowerOutletError.outletUnreachable(target.accessory.name)
        }
        guard let characteristic = target.service.characteristics.first(where: {
            $0.characteristicType == HMCharacteristicTypePowerState
        }) else {
            throw HomeKitPowerOutletError.missingPowerCharacteristic(target.accessory.name)
        }

        for _ in 0..<3 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                characteristic.writeValue(enabled) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(700))
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                characteristic.readValue { _ in continuation.resume() }
            }
            if (characteristic.value as? NSNumber)?.boolValue == enabled {
                refreshOutlets()
                return
            }
        }
        throw HomeKitPowerOutletError.powerStateDidNotChange(target.accessory.name)
    }

    /// Writes a colour light by accessory/service name. This intentionally uses a
    /// zone name rather than a stored HomeKit object so future left/right zones
    /// can share the same sampler and simply provide different target names.
    func setLight(named configuredName: String, hue: Double, saturation: Double, brightness: Double, updateBrightness: Bool) async throws {
        ambientWriteInProgress = true
        defer { ambientWriteInProgress = false }
        start()
        try await waitUntilReady()
        guard authorizationStatus.contains(.authorized) else {
            throw HomeKitPowerOutletError.accessUnavailable
        }
        let desired = Self.normalizedName(configuredName)
        let colourServices = homeManager?.homes.flatMap(\.accessories).flatMap({ accessory in
            accessory.services.map { (accessory, $0) }
        }).filter { _, service in
            service.characteristics.contains(where: { $0.characteristicType == HMCharacteristicTypeHue })
        } ?? []
        let target = colourServices.first(where: { accessory, service in
            let accessoryName = Self.normalizedName(accessory.name)
            let serviceName = Self.normalizedName(service.name)
            return accessoryName == desired || serviceName == desired
                || accessoryName.contains(desired) || desired.contains(accessoryName)
                || serviceName.contains(desired) || desired.contains(serviceName)
        })
        guard let target else {
            let available = colourServices.map { "\($0.0.name) · \($0.1.name)" }.joined(separator: ", ")
            print("[AmbientLighting] target ‘\(configuredName)’ not found; colour lights: \(available)")
            UserDefaults.standard.set(available.isEmpty ? "none" : available, forKey: "steam.ambientVisibleLights")
            throw HomeKitPowerOutletError.outletNotFound
        }
        UserDefaults.standard.set("\(target.0.name) · \(target.1.name)", forKey: "steam.ambientMatchedLight")
        guard target.0.isReachable else {
            throw HomeKitPowerOutletError.outletUnreachable(target.0.name)
        }
        var values: [(String, Double)] = [
            (HMCharacteristicTypeHue, min(max(hue, 0), 360)),
            (HMCharacteristicTypeSaturation, min(max(saturation, 0), 100)),
        ]
        let needsPreparation = !preparedAmbientServices.contains(target.1.uniqueIdentifier)
        if needsPreparation {
            ambientLightSnapshot = await captureAmbientState(service: target.1)
        }
        if needsPreparation || updateBrightness {
            values.append((HMCharacteristicTypeBrightness, min(max(brightness, 1), 100)))
        }
        for (type, value) in values {
            guard let characteristic = target.1.characteristics.first(where: { $0.characteristicType == type }) else { continue }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                characteristic.writeValue(value) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
        if needsPreparation, let power = target.1.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypePowerState }) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                power.writeValue(true) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
        if needsPreparation {
            preparedAmbientServices.insert(target.1.uniqueIdentifier)
            print("[AmbientLighting] connected target=\(target.0.name) service=\(target.1.name)")
        }
    }

    /// Restores the exact state that was present before ambient mode first
    /// touched the light, including whether it was switched off.
    func restoreAmbientLight() async {
        // MainActor tasks are re-entrant across HomeKit callbacks. Wait until an
        // update already accepted at exit has completely finished before restoring.
        while ambientWriteInProgress {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let snapshot = ambientLightSnapshot else { return }
        ambientLightSnapshot = nil
        guard let service = homeManager?.homes
            .flatMap(\.accessories)
            .flatMap(\.services)
            .first(where: { $0.uniqueIdentifier == snapshot.serviceID }) else { return }

        let originalValues: [(String, Any?)] = [
            (HMCharacteristicTypeHue, snapshot.hue),
            (HMCharacteristicTypeSaturation, snapshot.saturation),
            (HMCharacteristicTypeBrightness, snapshot.brightness),
        ]
        for (type, value) in originalValues {
            guard let value,
                  let characteristic = service.characteristics.first(where: { $0.characteristicType == type }) else { continue }
            try? await write(value, to: characteristic)
        }
        if let value = snapshot.power,
           let power = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypePowerState }) {
            try? await write(value, to: power)
        }
        preparedAmbientServices.remove(snapshot.serviceID)
        UserDefaults.standard.set("restored original light state", forKey: "steam.ambientLastResult")
        print("[AmbientLighting] restored original light state")
    }

    private func captureAmbientState(service: HMService) async -> AmbientLightSnapshot {
        let types = [HMCharacteristicTypeHue, HMCharacteristicTypeSaturation, HMCharacteristicTypeBrightness, HMCharacteristicTypePowerState]
        for type in types {
            if let characteristic = service.characteristics.first(where: { $0.characteristicType == type }) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    characteristic.readValue { _ in continuation.resume() }
                }
            }
        }
        func value(_ type: String) -> Any? {
            service.characteristics.first(where: { $0.characteristicType == type })?.value
        }
        return AmbientLightSnapshot(
            serviceID: service.uniqueIdentifier,
            hue: value(HMCharacteristicTypeHue),
            saturation: value(HMCharacteristicTypeSaturation),
            brightness: value(HMCharacteristicTypeBrightness),
            power: value(HMCharacteristicTypePowerState)
        )
    }

    private func write(_ value: Any, to characteristic: HMCharacteristic) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(value) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        authorizationStatus = manager.authorizationStatus
        isReady = true
        refreshOutlets()
    }

    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        authorizationStatus = status
        refreshOutlets()
    }

    private func waitUntilReady() async throws {
        for _ in 0..<30 {
            if isReady { return }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
        throw HomeKitPowerOutletError.homeDataTimedOut
    }

    private func refreshOutlets() {
        guard let homeManager else { return }
        authorizationStatus = homeManager.authorizationStatus
        outlets = homeManager.homes
            .flatMap(\.accessories)
            .flatMap { accessory in
                accessory.services.compactMap { service -> HomeKitPowerOutlet? in
                    // Home Assistant helpers and template switches do not always bridge
                    // with HMServiceTypeSwitch, and some bridges omit the writable flag.
                    // The HomeKit On characteristic is the reliable power-control shape.
                    guard let characteristic = service.characteristics.first(where: {
                        $0.characteristicType == HMCharacteristicTypePowerState
                    }) else {
                        return nil
                    }
                    let id = Self.outletID(accessory: accessory, service: service)
                    let value = (characteristic.value as? NSNumber)?.boolValue
                    return HomeKitPowerOutlet(
                        id: id,
                        name: accessory.name,
                        serviceName: service.name,
                        isOutletService: service.serviceType == HMServiceTypeOutlet,
                        roomName: accessory.room?.name,
                        isReachable: accessory.isReachable,
                        isOn: value
                    )
                }
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        for home in homeManager.homes {
            for accessory in home.accessories {
                for service in accessory.services {
                    service.characteristics
                        .first {
                            $0.characteristicType == HMCharacteristicTypePowerState
                        }?
                        .readValue { [weak self] _ in
                            Task { @MainActor in self?.refreshValuesOnly() }
                        }
                }
            }
        }
    }

    private func refreshValuesOnly() {
        guard let homeManager else { return }
        outlets = outlets.map { outlet in
            guard let target = liveOutlet(withID: outlet.id, manager: homeManager),
                  let characteristic = target.service.characteristics.first(where: {
                      $0.characteristicType == HMCharacteristicTypePowerState
                  }) else {
                return outlet
            }
            return HomeKitPowerOutlet(
                id: outlet.id,
                name: target.accessory.name,
                serviceName: target.service.name,
                isOutletService: target.service.serviceType == HMServiceTypeOutlet,
                roomName: target.accessory.room?.name,
                isReachable: target.accessory.isReachable,
                isOn: (characteristic.value as? NSNumber)?.boolValue
            )
        }
    }

    private func liveOutlet(withID id: String) -> (accessory: HMAccessory, service: HMService)? {
        guard let homeManager else { return nil }
        return liveOutlet(withID: id, manager: homeManager)
    }

    private func liveOutlet(
        withID id: String,
        manager: HMHomeManager
    ) -> (accessory: HMAccessory, service: HMService)? {
        for accessory in manager.homes.flatMap(\.accessories) {
            for service in accessory.services where Self.outletID(accessory: accessory, service: service) == id {
                return (accessory, service)
            }
        }
        return nil
    }

    private static func outletID(accessory: HMAccessory, service: HMService) -> String {
        "\(accessory.uniqueIdentifier.uuidString)|\(service.uniqueIdentifier.uuidString)"
    }

    private static func normalizedName(_ value: String) -> String {
        String(
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        )
    }
}
