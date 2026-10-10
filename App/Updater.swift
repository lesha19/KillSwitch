import AppKit
import Sparkle
import SwiftUI

/// Sparkle 2. Feed URL, EdDSA public key and the daily schedule live in Info.plist (project.yml).
/// «Обновлять автоматически» (SUAutomaticallyUpdate, on by default, ADR 0012): Sparkle downloads
/// the update in the background and we install it as soon as the app is not in use. Quitting or
/// replacing the app does not touch the VPN: the tunnel, pf and DNS live in the root daemons; the
/// relaunched app then has the daemon put the new helper in place without a drop.
@MainActor
@Observable
final class Updater {
    @ObservationIgnored private let installer = QuietInstaller()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    private(set) var canCheck = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: installer, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            // KVO calls back on the thread that changed the value, not necessarily the main one
            Task { @MainActor in self?.canCheck = value }
        }
        automaticallyUpdates = controller.updater.automaticallyDownloadsUpdates
    }

    func check() { controller.updater.checkForUpdates() }

    /// Sparkle keeps the choice in the app's defaults (SUAutomaticallyUpdate).
    var automaticallyUpdates = true {
        didSet {
            if controller.updater.automaticallyDownloadsUpdates != automaticallyUpdates {
                controller.updater.automaticallyDownloadsUpdates = automaticallyUpdates
            }
        }
    }
}

/// A downloaded automatic update is installed (and the app relaunched) as soon as KillSwitch is
/// not the active app, checked every minute: nobody has to quit it or drag anything.
final class QuietInstaller: NSObject, SPUUpdaterDelegate {
    @MainActor private var install: (() -> Void)?
    @MainActor private var timer: Timer?

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            install = immediateInstallHandler
            installWhenIdle()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.installWhenIdle() }
            }
        }
        return true
    }

    @MainActor private func installWhenIdle() {
        guard let install, !NSApp.isActive else { return }
        self.install = nil
        timer?.invalidate()
        timer = nil
        install()
    }
}

struct CheckForUpdatesButton: View {
    let updater: Updater

    var body: some View {
        Button("Проверить обновления…") { updater.check() }
            .disabled(!updater.canCheck)
    }
}
