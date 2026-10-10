import SwiftUI

/// The one error shown at the top of the window (spec §6): what happened, what to do, a button,
/// the raw text under «Подробнее», and ✕ to hide it until it happens again.
struct ErrorBanner: View {
    let error: UserError
    /// Nil hides the button (e.g. «Открыть кабинет» without a link).
    let action: UserError.Action?
    let perform: (UserError.Action) -> Void
    let dismiss: () -> Void
    @State private var showDetails = false

    var body: some View {
        Banner(icon: "exclamationmark.triangle.fill", title: error.title, message: error.message, dismiss: dismiss) {
            if let action {
                Button(action.title) { perform(action) }
            }
            if !error.details.isEmpty && error.details != error.message {
                Button(showDetails ? "Скрыть подробности" : "Подробнее") { showDetails.toggle() }
                    .buttonStyle(.link)
            }
        } footer: {
            if showDetails {
                Text(error.details).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The most important current error of the app with its action wired up; hidden by ✕ until a
/// different error comes or this one goes away and comes back. Without an error it shows
/// `fallback` (the next notice), so the screen never has more than one.
struct TopErrorBanner<Fallback: View>: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @Environment(\.openSettings) private var openSettings
    @State private var dismissed: String?
    /// «Выбрать другой сервер…» opens the server picker of the view that shows the banner.
    var chooseServer: () -> Void = {}
    @ViewBuilder var fallback: () -> Fallback

    private enum Source { case helper, serverList, latency, subscription }

    var body: some View {
        let current = top
        Group {
            if let current, key(current.error) != dismissed {
                ErrorBanner(error: current.error, action: available(current.error.action),
                            perform: { perform($0, source: current.source) },
                            dismiss: { dismissed = key(current.error) })
            } else {
                fallback()
            }
        }
        .onChange(of: current.map { key($0.error) }) { _, new in
            if new == nil { dismissed = nil }
        }
    }

    private var top: (error: UserError, source: Source)? {
        if let error = control.error { return (error, .helper) }
        if control.coreRunning, let error = control.proxiesError { return (error, .serverList) }
        if let error = control.coreError { return (error, .latency) }
        if let error = client.lastError { return (error, .subscription) }
        return nil
    }

    private func key(_ error: UserError) -> String { error.title + "\n" + error.details }

    private func available(_ action: UserError.Action?) -> UserError.Action? {
        if action == .openAccount && client.status.accountURL == nil { return nil }
        return action
    }

    private func perform(_ action: UserError.Action, source: Source) {
        switch action {
        case .repair: control.install()
        case .restartVPN: control.restartCore()
        case .openLoginItems: NSWorkspace.shared.open(SystemSettings.loginItems)
        case .editSubscription: openSettings()
        case .openAccount: if let url = client.status.accountURL { NSWorkspace.shared.open(url) }
        case .approveServers: Task { await client.confirmNewServers() }
        case .recheck: Task { await control.testAllDelays() }
        case .chooseServer: chooseServer()
        case .copyDiagnostics: DiagnosticsCopy.copy(control: control, client: client)
        case .retry:
            switch source {
            case .subscription: Task { await client.update(interactive: true) }
            case .serverList: control.loadProxies(force: true)
            case .latency: Task { await control.testAllDelays() }
            case .helper: control.install()
            }
        }
    }
}

/// Deep links into System Settings.
enum SystemSettings {
    static let loginItems = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    /// Login Items & Extensions, where «Сетевые расширения» are allowed.
    static let networkExtensions = loginItems
}

/// A notice on a tinted background. The colour is only in the icon and the background; the text
/// stays primary, so it reads at full contrast in both themes (spec §9.4).
struct Banner<Buttons: View, Footer: View>: View {
    let icon: String
    var tint: Color = .orange
    let title: String
    let message: String
    var dismiss: (() -> Void)?
    var dismissHelp = "Скрыть"
    @ViewBuilder var buttons: () -> Buttons
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.bold()).accessibilityAddTraits(.isHeader)
                if !message.isEmpty {
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if Buttons.self != EmptyView.self {
                    HStack(spacing: 12) { buttons() }.controlSize(.small)
                }
                if Footer.self != EmptyView.self {
                    footer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(dismissHelp)
                    .accessibilityLabel(dismissHelp)
            }
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

extension Banner where Footer == EmptyView {
    init(icon: String, tint: Color = .orange, title: String, message: String, dismiss: (() -> Void)? = nil,
         dismissHelp: String = "Скрыть", @ViewBuilder buttons: @escaping () -> Buttons) {
        self.init(icon: icon, tint: tint, title: title, message: message, dismiss: dismiss, dismissHelp: dismissHelp,
                  buttons: buttons, footer: { EmptyView() })
    }
}

/// An error under the control that caused it (settings, lists): title and message, raw text on hover.
struct InlineError: View {
    let error: UserError

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).font(.callout.bold())
                if !error.message.isEmpty {
                    Text(error.message).font(.callout)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .help(error.details)
        .textSelection(.enabled)
    }
}

/// A status line: the colour and the shape are in the icon, the text stays readable in both
/// themes (spec §9.3, §9.4).
struct StatusLabel: View {
    let text: String
    let systemImage: String
    let tint: Color

    init(_ text: String, systemImage: String, tint: Color) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }
}
