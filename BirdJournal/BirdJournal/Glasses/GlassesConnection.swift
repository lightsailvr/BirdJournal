import Foundation
import MWDATCore
import Observation
#if DEBUG
import MWDATMockDevice
import UIKit
#endif

/// One linked pair of glasses as the phone screen shows it.
struct GlassesDeviceStatus: Identifiable, Equatable {
    let id: DeviceIdentifier
    var name: String
    var type: DeviceType
    var state: DeviceState
}

extension GlassesDeviceStatus {
    /// The link as the phone screens name it.
    var linkText: String {
        switch state.linkState {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected: "Not connected"
        }
    }
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

    /// The registration state as the phone screens name it.
    var registrationText: String {
        switch registrationState {
        case .unavailable: "Unavailable"
        case .available: "Not registered"
        case .registering: "Registering…"
        case .registered: "Registered"
        @unknown default: "Unknown"
        }
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
        case DeviceSessionStartError.sessionDidNotStart(let error): error
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
            return GlassesDeviceStatus(id: identifier, name: device.nameOrId(), type: device.deviceType(), state: device.currentState)
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

    /// The port of Mock Device Kit's preview server: open `http://127.0.0.1:9000/` in Chrome with the Meta Ray-Ban
    /// Display Simulator extension to see and drive the mock lens (simulator only, not on a physical iPhone). The
    /// simulators share the Mac's loopback, so only one app can hold a port: `-mockPreviewPort 9001` picks another
    /// (`scripts/mock-lens-in-chrome.sh`, issue #82).
    static var mockPreviewPort: UInt16 {
        UInt16(exactly: UserDefaults.standard.integer(forKey: "mockPreviewPort")).flatMap { $0 == 0 ? nil : $0 } ?? 9000
    }
    @ObservationIgnored private var previewServer: Task<Void, Never>?

    /// Pairs a registered, permission-granted mock Meta Ray-Ban Display that is powered on, unfolded and worn, and
    /// starts the preview server for the Chrome extension.
    func pairMockGlasses() {
        do {
            MockDeviceKit.shared.enable()
            let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
            glasses.powerOn()
            glasses.unfold()
            glasses.don()
            mockGlasses = glasses
            isMockPaired = true
            previewServer = Task { [weak self] in
                do {
                    let port = try await MockDeviceKit.shared.startTestServer(port: Self.mockPreviewPort)
                    GlassesLog.shared.note("Display preview server on http://127.0.0.1:\(port)/")
                } catch {
                    self?.errorMessage = "Display preview server: \(error.localizedDescription)"
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stops the preview server, then unpairs and disables, each awaited: the teardown order the DAT docs give, and
    /// the one the mock suites use (issue #82).
    func unpairMockGlasses() async {
        let glasses = mockGlasses
        mockGlasses = nil
        isMockPaired = false
        await previewServer?.value
        previewServer = nil
        await MockDeviceKit.shared.stopTestServer()
        if let glasses { await MockDeviceKit.shared.unpairDevice(glasses) }
        await MockDeviceKit.shared.disable()
    }

    func setMockWorn(_ worn: Bool) {
        if worn { mockGlasses?.don() } else { mockGlasses?.doff() }
    }

    /// What the mock lens is showing, as a view to embed in the phone screen. Nil unless a mock is paired.
    func makeMockDisplayPreview() -> UIView? {
        mockGlasses?.services.display.createPreviewView()
    }

    /// Stand-ins for the Neural Band. Dropped by the mock unless Inputs is attached and active.
    enum MockInput: CaseIterable, Identifiable {
        case navLeft, navRight, navUp, navDown, select, back

        var id: Self { self }

        var title: String {
            switch self {
            case .navLeft: "←"
            case .navRight: "→"
            case .navUp: "↑"
            case .navDown: "↓"
            case .select: "Tap"
            case .back: "Back"
            }
        }
    }

    func injectMockInput(_ input: MockInput) {
        guard let kit = mockGlasses?.services.input else { return }
        switch input {
        case .navLeft: kit.navLeft()
        case .navRight: kit.navRight()
        case .navUp: kit.navUp()
        case .navDown: kit.navDown()
        case .select: kit.select()
        case .back: kit.back()
        }
    }
    #endif
}
