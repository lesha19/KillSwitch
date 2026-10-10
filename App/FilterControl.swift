import Foundation
import NetworkExtension
import Observation
import SystemExtensions

/// Second layer: the content filter system extension (Filter/). The app installs it, keeps its
/// lists in step with /Library/KillSwitch and switches it on and off together with the pf rules.
@MainActor
@Observable
final class FilterControl: NSObject {
    static let extensionID = "com.lesha19.KillSwitch.Filter"

    enum Status: Equatable { case unknown, notInstalled, waitingForApproval, off, on, failed(String) }

    private(set) var status: Status = .unknown
    private var lastConfig: [String: AnyHashable]?
    private var lastEnabled: Bool?
    /// The bundled extension, submitted to replace an older activated one, waits for the switch in
    /// System Settings; the old one keeps filtering meanwhile (ADR 0012 addendum).
    private(set) var updateWaitingForApproval = false
    private var propertiesRequest: ObjectIdentifier?
    private var updateRequest: ObjectIdentifier?

    override init() {
        super.init()
        Task {
            await loadStatus()
            // also right after a Sparkle update: Sparkle relaunches the new app
            checkForUpdate()
        }
    }

    /// macOS keeps the extension it activated until the app asks again: ask which one runs and
    /// replace it only when the bundled one is newer. Reading the properties asks the user nothing.
    private func checkForUpdate() {
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        request.delegate = self
        propertiesRequest = ObjectIdentifier(request)
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    fileprivate func found(_ installed: [FilterUpgrade.Installed]) {
        propertiesRequest = nil
        guard let bundled = Self.bundledExtension else { return }
        switch FilterUpgrade.decide(installed: installed, bundledShort: bundled.short, bundledBuild: bundled.build) {
        case .replace:
            let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
            request.delegate = self
            updateRequest = ObjectIdentifier(request)
            OSSystemExtensionManager.shared.submitRequest(request)
        case .awaitingApproval:
            updateWaitingForApproval = true
        case .current, .notActive:
            updateWaitingForApproval = false
        }
    }

    /// Contents/Library/SystemExtensions/<id>.systemextension of this app.
    private static var bundledExtension: (short: String, build: String)? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Library/SystemExtensions/\(extensionID).systemextension")
        guard let info = Bundle(url: url)?.infoDictionary,
              let short = info["CFBundleShortVersionString"] as? String, let build = info["CFBundleVersion"] as? String else { return nil }
        return (short, build)
    }

    /// Asks macOS to install (or update) the extension; the first time the user has to allow it
    /// in System Settings → General → Login Items & Extensions → Network Extensions.
    func install() {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        Task {
            let manager = NEFilterManager.shared()
            try? await manager.loadFromPreferences()
            try? await manager.removeFromPreferences()
            let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
            lastConfig = nil
            lastEnabled = nil
            status = .notInstalled
        }
    }

    /// Called on every refresh of the app; writes the filter's preferences only when something changed.
    func sync(config: [String: AnyHashable], enabled: Bool) {
        guard status == .on || status == .off, config != lastConfig || enabled != lastEnabled else { return }
        lastConfig = config
        lastEnabled = enabled
        Task { await save(config: config, enabled: enabled) }
    }

    private func save(config: [String: AnyHashable], enabled: Bool) async {
        let manager = NEFilterManager.shared()
        do {
            try await manager.loadFromPreferences()
            let provider = manager.providerConfiguration ?? NEFilterProviderConfiguration()
            provider.filterSockets = true
            provider.filterPackets = false
            provider.vendorConfiguration = config
            manager.providerConfiguration = provider
            manager.localizedDescription = "KillSwitch"
            manager.isEnabled = enabled
            try await manager.saveToPreferences()
            status = enabled ? .on : .off
        } catch {
            lastConfig = nil
            status = .failed(error.localizedDescription)
        }
    }

    private func loadStatus() async {
        let manager = NEFilterManager.shared()
        try? await manager.loadFromPreferences()
        if manager.providerConfiguration == nil {
            status = .notInstalled
        } else {
            status = manager.isEnabled ? .on : .off
        }
    }

    fileprivate func activated() {
        // a fresh install has no preferences yet; sync() writes them on the next refresh
        status = .off
        lastConfig = nil
        lastEnabled = nil
    }

    fileprivate func failed(_ message: String) { status = .failed(message) }
    fileprivate func waiting() { status = .waitingForApproval }

    /// The delegate's answers for the launch-time requests: they leave `status` alone, the filter
    /// that ran keeps running (and its preferences stay as they are) until macOS swaps it.
    fileprivate func finished(_ request: ObjectIdentifier) {
        if request == propertiesRequest { propertiesRequest = nil; return }
        if request == updateRequest { updateRequest = nil; updateWaitingForApproval = false; return }
        activated()
    }

    fileprivate func needsApproval(_ request: ObjectIdentifier) {
        if request == updateRequest { updateWaitingForApproval = true } else { waiting() }
    }

    fileprivate func failed(_ request: ObjectIdentifier, _ message: String) {
        if request == propertiesRequest { propertiesRequest = nil; return }
        if request == updateRequest { updateRequest = nil; updateWaitingForApproval = false; return }
        failed(message)
    }
}

extension FilterControl: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        let id = ObjectIdentifier(request)
        Task { @MainActor in self.needsApproval(id) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let id = ObjectIdentifier(request)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let id = ObjectIdentifier(request)
        let message = error.localizedDescription
        Task { @MainActor in self.failed(id, message) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let installed = properties.map {
            FilterUpgrade.Installed(shortVersion: $0.bundleShortVersion, build: $0.bundleVersion, enabled: $0.isEnabled,
                                    awaitingApproval: $0.isAwaitingUserApproval, uninstalling: $0.isUninstalling)
        }
        Task { @MainActor in self.found(installed) }
    }
}
