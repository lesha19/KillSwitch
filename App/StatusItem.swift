import AppKit
import SwiftUI

/// The menu bar icon (spec §5.1, ADR 0011). MenuBarExtra has no right click, so it is an AppKit
/// status item: a click opens the main screen (`HomeView`) in a popover, a right click or ⌃-click
/// the compact menu (MenuBarMenu). Everything that shows more goes to the one window (Router).
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    private static var shared: StatusItem?

    /// Called once the app has finished launching.
    static func install(control: KillSwitchControl, client: VPNClient, updater: Updater) {
        guard shared == nil else { return }
        shared = StatusItem(control: control, client: client, updater: updater)
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let control: KillSwitchControl
    private let client: VPNClient

    private init(control: KillSwitchControl, client: VPNClient, updater: Updater) {
        self.control = control
        self.client = client
        super.init()
        popover.behavior = .transient
        let home = HomeView(style: .popover, close: { [weak self] in self?.popover.performClose(nil) })
            .environment(control).environment(client).environment(updater)
        let host = NSHostingController(rootView: home)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            // SwiftUI side of the icon: the window opener, the image and VoiceOver (MenuBarLabel)
            let label = NSHostingView(rootView: MenuBarLabel(button: button).environment(control).environment(client))
            label.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            button.addSubview(label)
        }
        // whatever opens the window closes the popover
        Router.shared.willShowWindow = { [weak self] in self?.popover.performClose(nil) }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        switch MenuBarMenu.click(rightButton: event?.type == .rightMouseUp,
                                 controlKey: event?.modifierFlags.contains(.control) ?? false) {
        case .popover: togglePopover()
        case .menu: showMenu()
        }
    }

    private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        menu.delegate = self
        for entry in MenuBarMenu.entries(status: control.status(client), busy: control.busy,
                                         coreConfigured: control.coreConfigured, fastestAvailable: fastest != nil) {
            guard let entry else { menu.addItem(.separator()); continue }
            let menuItem = NSMenuItem(title: entry.title, action: entry.enabled ? #selector(choose(_:)) : nil, keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = entry.item
            menuItem.isEnabled = entry.enabled
            menu.addItem(menuItem)
        }
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.performClick(nil)   // shows the menu under the icon
    }

    func menuDidClose(_ menu: NSMenu) {
        item.menu = nil   // the next click opens the popover again
    }

    /// «Самый быстрый» of the server list, connected or not.
    private var fastest: ServerPicker.Entry? {
        (control.proxies ?? client.profileProxies).flatMap { ServerPicker.entries($0).first(where: \.isFastest) }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuBarMenu.Item else { return }
        switch action {
        case .connect: control.coreOn()
        case .disconnect: control.coreOff()
        case .fastest: if let fastest { control.choose(fastest) }
        case .openApp: Router.shared.go(.openWindow)
        case .leakTest: Router.shared.go(.leakTest)
        case .quit: NSApp.terminate(nil)
        }
    }
}

/// The SwiftUI side of the status item, an invisible view inside its button: hands SwiftUI's
/// window opener to the Router, draws the summary's icon into the button, announces a change of
/// the status to VoiceOver at most every 5 s (spec §9.2) and, on a Mac without the service, opens
/// «Начало работы» once.
private struct MenuBarLabel: View {
    let button: NSStatusBarButton
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @Environment(\.openWindow) private var openWindow
    @State private var throttle = Throttle(interval: 5)
    @State private var offeredSetup = false

    var body: some View {
        let status = control.status(client)
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear { Router.shared.openWindow = { openWindow(id: MainWindow.id) } }
            .onChange(of: status, initial: true) { _, status in
                let image = NSImage(named: status.icon)
                image?.isTemplate = true
                button.image = image
                button.toolTip = status.accessibilityLabel
                button.setAccessibilityLabel(status.accessibilityLabel)
            }
            .onChange(of: control.speed, initial: true) { _, speed in
                // «Скорость в строке меню»: small digits that keep their width
                button.attributedTitle = NSAttributedString(
                    string: speed.map { " " + TrafficSpeed.label($0) } ?? "",
                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)])
            }
            .onChange(of: status.title) { _, title in
                guard throttle.allow("status", now: Date()) else { return }
                AccessibilityNotification.Announcement("KillSwitch: " + title).post()
            }
            .onChange(of: status == .notInstalled, initial: true) { _, notInstalled in
                guard notInstalled, !offeredSetup else { return }
                offeredSetup = true
                Router.shared.openWindow = { openWindow(id: MainWindow.id) }   // may run before onAppear
                Router.shared.go(.onboarding)
            }
    }
}
