import AppKit
import UserNotifications

/// Posts the notifications of spec §7 and handles their buttons. Permission is asked in the
/// first-run wizard, never at the moment of an event; without it nothing is shown.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    weak var control: KillSwitchControl?
    weak var client: VPNClient?
    /// SwiftUI's openWindow, handed over by a view (the menu bar label always exists).
    var openWindow: ((String) -> Void)?

    private var throttle = Throttle(interval: UserNotice.interval)

    override private init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let categories = [UserNotice.Action.connect, .openApp, .renew, .approve, .openLoginItems, .check].map { action in
            UNNotificationCategory(identifier: action.rawValue,
                                   actions: [UNNotificationAction(identifier: action.rawValue, title: action.title,
                                                                  options: [.foreground])],
                                   intentIdentifiers: [])
        }
        center.setNotificationCategories(Set(categories))
    }

    func post(_ notice: UserNotice) {
        if let setting = notice.setting, !(UserDefaults.standard.object(forKey: setting.rawValue) as? Bool ?? true) { return }
        guard throttle.allow(notice.key, now: Date()) else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        if let action = notice.action { content.categoryIdentifier = action.rawValue }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // a click on the notification itself carries its category's action too
        let id = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? response.notification.request.content.categoryIdentifier : response.actionIdentifier
        await MainActor.run { perform(UserNotice.Action(rawValue: id)) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func perform(_ action: UserNotice.Action?) {
        switch action {
        case .connect: control?.coreOn()
        case .renew:
            if let url = client?.status.accountURL { NSWorkspace.shared.open(url) } else { open("main") }
        case .approve: Task { await client?.confirmNewServers() }
        case .openLoginItems: NSWorkspace.shared.open(SystemSettings.loginItems)
        case .check: open(LeakTestView.windowID)
        case .openApp, nil: open("main")
        }
    }

    private func open(_ window: String) {
        openWindow?(window)
        NSApp.activate()
    }
}
