import AppKit
import Observation

/// The one window of the app (ADR 0008): which section it shows and whether «Начало работы» is
/// up. Menus, the popover, notifications, the widget and links all come here; none of them opens
/// a second window.
@MainActor @Observable
final class Router {
    static let shared = Router()

    /// UserDefaults keys: the last section, and the last «Настройки» pane for ⌘,.
    static let sectionKey = "mainSection"
    static let paneKey = "settingsTab"

    var section: AppSection {
        didSet {
            UserDefaults.standard.set(section.id, forKey: Self.sectionKey)
            if case .settings(let pane) = section { UserDefaults.standard.set(pane.rawValue, forKey: Self.paneKey) }
        }
    }
    /// «Начало работы», a sheet on the window.
    var onboarding = false
    /// A `killswitch://` link waiting for «Добавить» / «Отключить» (DeepLinks); one at a time.
    var linkRequest: DeepLink.Confirmation?

    /// SwiftUI's openWindow for the main window, handed over by the menu bar label (which always
    /// exists). A `Window` scene has one instance: this fronts it when it is already open.
    @ObservationIgnored var openWindow: (() -> Void)?
    /// Closes the menu bar popover before the window comes forward (StatusItem).
    @ObservationIgnored var willShowWindow: (() -> Void)?

    private init() {
        section = UserDefaults.standard.string(forKey: Self.sectionKey).flatMap(AppSection.init(id:)) ?? .home
    }

    func go(_ route: Route) {
        switch route {
        case .window: break
        case .section(let section): self.section = section
        case .onboarding: onboarding = true
        }
        willShowWindow?()
        openWindow?()
        NSApp.activate()
    }

    func go(_ command: Navigation.Command) {
        go(Navigation.route(command, lastSettingsPane: UserDefaults.standard.string(forKey: Self.paneKey)))
    }
}
