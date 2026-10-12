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
    @ObservationIgnored private let alertFocus = UpdateAlertFocus()   // Sparkle keeps its delegates weak
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    private(set) var canCheck = false
    /// #35: another build is in place of this one (Sparkle installed it but the app was not
    /// relaunched): «Перезапустить» on the main screen, and on its own once the app is in the background.
    private(set) var relaunchPending = false
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private let runningBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    /// Waits for this process to end, then opens the new build (one, however often it is asked).
    @ObservationIgnored private var opener: Process?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: installer, userDriverDelegate: alertFocus)
        alertFocus.updater = controller.updater
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            // KVO calls back on the thread that changed the value, not necessarily the main one:
            // the updater is read only after the hop to the main actor
            Task { @MainActor in
                guard let self else { return }
                self.canCheck = self.controller.updater.canCheckForUpdates
            }
        }
        automaticallyUpdates = controller.updater.automaticallyDownloadsUpdates
        // #11: a check that could not reach the appcast goes again through the VPN once it connects
        NotificationCenter.default.addObserver(forName: UpdateRetry.vpnConnected, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryAfterNetworkFailure() }
        }
        _ = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInstalledBuild() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInstalledBuild() }
        }
    }

    private func checkInstalledBuild() {
        relaunchPending = UpdateRelaunch.isPending(running: runningBuild, onDisk: UpdateRelaunch.buildOnDisk(Bundle.main.bundleURL))
        // in the background and nothing half-done in a sheet: as QuietInstaller would have done
        if relaunchPending, !NSApp.isActive, !NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
            relaunch()
        }
    }

    /// Opens the bundle again once this process has ended (the VPN lives in the root daemons).
    func relaunch() {
        if opener?.isRunning != true {
            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/bin/sh")
            opener.arguments = UpdateRelaunch.relaunchArguments(pid: ProcessInfo.processInfo.processIdentifier,
                                                                bundlePath: Bundle.main.bundlePath)
            do { try opener.run() } catch { return }
            self.opener = opener
        }
        Router.shared.dropSheets()   // first: a sheet whose binding is still true comes back
        UpdateRelaunch.closeSheets(NSApp.windows)
        StartMinimised.markRelaunch()
        NSApp.terminate(nil)
    }

    private func retryAfterNetworkFailure() {
        guard installer.lastCheckFailed, controller.updater.canCheckForUpdates else { return }
        installer.lastCheckFailed = false
        controller.updater.checkForUpdatesInBackground()
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

    /// «Бета-версии» (#16), kept in the user defaults; QuietInstaller gives Sparkle the channels.
    var betaUpdates = UpdateChannel.isBeta() {
        didSet {
            UserDefaults.standard.set(betaUpdates, forKey: UpdateChannel.betaKey)
            // Sparkle: after a change of the allowed channels, so the next check uses them
            controller.updater.resetUpdateCycleAfterShortDelay()
        }
    }
}

/// A downloaded automatic update is installed (and the app relaunched) as soon as KillSwitch is
/// not the active app, checked every minute: nobody has to quit it or drag anything.
final class QuietInstaller: NSObject, SPUUpdaterDelegate {
    @MainActor private var install: (() -> Void)?
    /// The last check ended without reaching the appcast (UpdateRetry).
    @MainActor var lastCheckFailed = false

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { lastCheckFailed = UpdateRetry.isNetworkFailure(error) }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannel.allowed(beta: UpdateChannel.isBeta())
    }
    @MainActor private var timer: Timer?

    /// #35: Sparkle's agent asks the app to quit right after this; AppKit refuses that while a
    /// window has a sheet («Начало работы» opens by itself without the helper), so they are closed.
    /// Called on the main thread once per install that relaunches: the button and the quiet one.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            Router.shared.dropSheets()   // first: a sheet whose binding is still true comes back
            _ = UpdateRelaunch.closeSheets(NSApp.windows)
            StartMinimised.markRelaunch()   // a closed window stays closed after the relaunch (#51)
        }
    }

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

/// #51: with the window closed the app is .accessory, a background app to Sparkle, which would
/// show a scheduled update's alert behind the other apps. It comes with the window instead
/// (Sparkle's gentle reminders); user-initiated checks stay Sparkle's.
@MainActor
final class UpdateAlertFocus: NSObject, @preconcurrency SPUStandardUserDriverDelegate {   // Sparkle calls on the main thread
    weak var updater: SPUUpdater?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        NSApp.activationPolicy() != .accessory
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        Router.shared.go(.window)
        // Sparkle: a check while the update waits brings its alert forward (after Router's activation)
        DispatchQueue.main.async { [weak self] in self?.updater?.checkForUpdates() }
    }
}

/// #35: shown while another build waits in place of this one.
struct RelaunchBanner: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        if updater.relaunchPending {
            Banner(icon: "arrow.clockwise.circle.fill", tint: .blue, title: String(localized: "Обновление установлено"),
                   message: String(localized: "Перезапусти KillSwitch, чтобы работала новая версия. VPN не прервётся.")) {
                Button("Перезапустить") { updater.relaunch() }
            }
        }
    }
}

struct CheckForUpdatesButton: View {
    let updater: Updater

    var body: some View {
        Button("Проверить обновления…") { updater.check() }
            .disabled(!updater.canCheck)
    }
}
