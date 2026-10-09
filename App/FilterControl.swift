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

    override init() {
        super.init()
        Task { await loadStatus() }
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
}

extension FilterControl: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.waiting() }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in self.activated() }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.failed(message) }
    }
}
