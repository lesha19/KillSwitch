import SwiftUI

@main
struct KillSwitchApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var control: KillSwitchControl
    @State private var client: VPNClient
    @State private var leakTester = LeakTester()
    @State private var autoConnector: AutoConnector
    @State private var updater: Updater

    init() {
        let control = KillSwitchControl()
        let client = VPNClient(control: control)
        let updater = Updater()
        _control = State(initialValue: control)
        _client = State(initialValue: client)
        _updater = State(initialValue: updater)
        _autoConnector = State(initialValue: AutoConnector(control: control, client: client))
        Notifier.shared.control = control
        Notifier.shared.client = client
        ShortcutTarget.control = control
        ShortcutTarget.client = client
        // spec §5.1, Р3: the menu bar icon; a click opens the main screen as a popover, a right
        // click a compact menu (ADR 0011)
        DispatchQueue.main.async { StatusItem.install(control: control, client: client, updater: updater) }
    }

    var body: some Scene {
        // The one window (ADR 0008): a `Window`, not a `WindowGroup`, so there is never a second
        // one; macOS restores its size and place. No `Settings` scene: ⌘, opens «Настройки» here.
        Window("KillSwitch", id: MainWindow.id) {
            MainWindow()
                .environment(control)
                .environment(client)
                .environment(leakTester)
                .environment(autoConnector)
                .environment(updater)
        }
        .defaultSize(width: 860, height: 640)
        // «Запускать без окна» (or an update relaunch with the window closed, #51): neither opened
        // nor restored at launch, only the menu bar icon
        .defaultLaunchBehavior(StartMinimised.atLaunch ? .suppressed : .automatic)
        .restorationBehavior(StartMinimised.atLaunch ? .disabled : .automatic)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: updater) }
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { Router.shared.go(.settings) }.keyboardShortcut(",")
            }
            CommandMenu("VPN") {
                Button("Главная") { Router.shared.go(.section(.home)) }.keyboardShortcut("0")
                Button("Серверы") { Router.shared.go(.servers) }.keyboardShortcut("l")
                Button("Проверка утечек") { Router.shared.go(.leakTest) }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Журнал защиты") { Router.shared.go(.section(.log)) }
                Divider()
                Button("Скопировать диагностику") { DiagnosticsCopy.copy(control: control, client: client) }
            }
            CommandGroup(replacing: .help) {
                Button("Как это работает") { Router.shared.go(.help) }
            }
        }
    }
}

/// `killswitch://…` links (the widget opens `killswitch://home`; the rest: DeepLinks, ADR 0029).
///
/// #51 (ADR 0011): closing the window leaves the app in the menu bar, without a Dock icon; Router
/// brings the icon back with the window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if StartMinimised.atLaunch { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func windowWillClose(_ note: Notification) {
        // SwiftUI names the `Window` scene's NSWindow after its id
        if (note.object as? NSWindow)?.identifier?.rawValue == MainWindow.id { NSApp.setActivationPolicy(.accessory) }
    }

    /// SwiftUI's own answer for an app of one `Window` is yes: it quit with the window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the running app again (Finder, Launchpad, Spotlight) with the window closed: the
    /// window, through Router like everything else. With a Dock icon AppKit's own reopen stays.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard NSApp.activationPolicy() == .accessory else { return true }
        MainActor.assumeIsolated { Router.shared.go(.window) }
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { DeepLinks.open(url) }
        }
    }
}
