import Foundation
import MWDATCore
import Observation
#if DEBUG
import MWDATMockDevice
#endif

/// One linked pair of glasses as the phone screen shows it.
struct GlassesDeviceStatus: Identifiable, Equatable {
    let id: DeviceIdentifier
    var name: String
    var type: DeviceType
    var state: DeviceState
}

/// Registration with the Meta AI app and the list of linked glasses (spec "Glasses adapter"). Holds every
/// toolkit listener token for registration and device state; the audio stream lives in `GlassesAudioSource`.
@Observable
final class GlassesConnection {
    private(set) var registrationState: RegistrationState
    private(set) var devices: [GlassesDeviceStatus] = []
    /// Set when a session fails because the DAT app on the glasses is out of date.
    private(set) var glassesAppUpdateRequired = false
    var errorMessage: String?

    let wearables: any WearablesInterface

    @ObservationIgnored private let tokens = ListenerTokenBag()
    @ObservationIgnored private var deviceTokens: [DeviceIdentifier: ListenerTokenBag] = [:]

    init(wearables: any WearablesInterface = Wearables.shared) {
        self.wearables = wearables
        registrationState = wearables.registrationState
        wearables.addRegistrationStateListener { [weak self] state in
            Task { @MainActor in self?.registrationState = state }
        }.store(in: tokens)
        wearables.addDevicesListener { [weak self] identifiers in
            Task { @MainActor in self?.updateDevices(identifiers) }
        }.store(in: tokens)
        updateDevices(wearables.devices)
    }

    /// The first connected glasses, used for battery, charging and thermal readings.
    var connectedDevice: GlassesDeviceStatus? {
        devices.first { $0.state.linkState == .connected }
    }

    // MARK: - Registration

    func register() async {
        await perform { try await wearables.startRegistration() }
    }

    func unregister() async {
        await perform { try await wearables.startUnregistration() }
    }

    /// Forwards a Meta AI callback (`birdjournal://…?metaWearablesAction=…`). Other links are ignored.
    func handle(url: URL) async {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else { return }
        await perform { _ = try await wearables.handleUrl(url) }
    }

    // MARK: - Updates

    func openFirmwareUpdate() async {
        await perform { try await wearables.openFirmwareUpdate() }
    }

    func openGlassesAppUpdate() async {
        await perform {
            try await wearables.openDATGlassesAppUpdate()
            glassesAppUpdateRequired = false
        }
    }

    /// Called when a glasses session fails, so the phone screen can offer the matching update.
    func noteSessionFailure(_ error: any Error) {
        let sessionError: DeviceSessionError? = switch error {
        case let error as DeviceSessionError: error
        case GlassesAudioSource.StartError.sessionDidNotStart(let error): error
        default: nil
        }
        if sessionError == .datAppOnTheGlassesUpdateRequired {
            glassesAppUpdateRequired = true
        }
    }

    // MARK: - Private

    private func perform(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateDevices(_ identifiers: [DeviceIdentifier]) {
        for removed in Set(deviceTokens.keys).subtracting(identifiers) {
            deviceTokens.removeValue(forKey: removed)?.clear()
        }
        devices = identifiers.compactMap { identifier in
            guard let device = wearables.deviceForIdentifier(identifier) else { return nil }
            if deviceTokens[identifier] == nil {
                let bag = ListenerTokenBag()
                device.addDeviceStateListener { [weak self] state in
                    Task { @MainActor in self?.updateState(state, for: identifier) }
                }.store(in: bag)
                deviceTokens[identifier] = bag
            }
            return GlassesDeviceStatus(
                id: identifier,
                name: device.nameOrId(),
                type: device.deviceType(),
                state: DeviceState(
                    linkState: device.linkState,
                    compatibility: device.compatibility(),
                    batteryLevel: device.batteryLevel,
                    chargingState: device.chargingState,
                    donState: device.donState,
                    hingeState: device.hingeState,
                    thermalLevel: device.thermalLevel
                )
            )
        }
    }

    private func updateState(_ state: DeviceState, for identifier: DeviceIdentifier) {
        guard let index = devices.firstIndex(where: { $0.id == identifier }) else { return }
        devices[index].state = state
    }

    // MARK: - Mock Device Kit

    #if DEBUG
    @ObservationIgnored private var mockGlasses: (any MockGlasses)?
    private(set) var isMockPaired = false

    /// Pairs a registered, permission-granted mock Meta Ray-Ban Display that is powered on, unfolded and worn.
    func pairMockGlasses() {
        do {
            MockDeviceKit.shared.enable()
            let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
            glasses.powerOn()
            glasses.unfold()
            glasses.don()
            mockGlasses = glasses
            isMockPaired = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unpairMockGlasses() async {
        mockGlasses = nil
        isMockPaired = false
        await MockDeviceKit.shared.disable()
    }

    func setMockWorn(_ worn: Bool) {
        if worn { mockGlasses?.don() } else { mockGlasses?.doff() }
    }
    #endif
}
