import AppKit
import SwiftUI

/// #22: the provider's announcement (`announce` header) on the main screen, the lowest notice:
/// shown until ✕, again only when the text changes. Plain text only (`Text(String)`).
struct ProviderAnnouncementBanner: View {
    @Environment(VPNClient.self) private var client
    @AppStorage("providerAnnouncementDismissed") private var dismissed = ""

    var body: some View {
        if let provider = client.status.provider, let text = provider.announcementToShow(dismissed: dismissed) {
            Banner(icon: "megaphone", tint: .blue, title: title, message: text,
                   dismiss: { dismissed = text }, dismissHelp: String(localized: "Скрыть сообщение")) {
                if let url = provider.announcementURL {
                    Button("Подробнее") { NSWorkspace.shared.open(url) }
                        .accessibilityHint(Text("Открывает ссылку из сообщения сервиса VPN"))
                }
            }
        }
    }

    private var title: String {
        if let name = client.status.title { String(localized: "Сообщение от «\(name)»") } else { String(localized: "Сообщение от сервиса VPN") }
    }
}

/// #22: the provider's support contacts (`support-url`, `support-email`) in «О программе».
/// Buttons only: the link itself is not shown (it may be the subscription link, #26).
struct ProviderSupportSection: View {
    @Environment(VPNClient.self) private var client

    var body: some View {
        if let provider = client.status.provider, provider.supportURL != nil || provider.supportMail != nil {
            Section("Поддержка сервиса VPN") {
                LabeledContent(client.status.title ?? String(localized: "Сервис VPN")) {
                    HStack {
                        if let url = provider.supportURL {
                            Button("Написать в поддержку") { NSWorkspace.shared.open(url) }
                                .accessibilityHint(Text("Открывает поддержку сервиса VPN"))
                        }
                        if let mail = provider.supportMail {
                            Button("Написать на почту") { NSWorkspace.shared.open(mail) }
                                .accessibilityHint(Text("Открывает письмо в поддержку сервиса VPN"))
                        }
                    }
                }
            }
        }
    }
}

extension View {
    /// #26: «Показать» of the subscription link is off when the provider sent `hide-url`.
    func hiddenByProvider(_ hidden: Bool) -> some View {
        disabled(hidden)
            .help(hidden ? String(localized: "Сервис VPN попросил не показывать ссылку") : "")
    }
}
