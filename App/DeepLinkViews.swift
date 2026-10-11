import OSLog
import SwiftUI

/// `killswitch://` links (#23, ADR 0029): what DeepLink decided, done by the app. A section opens
/// the window; «connect» runs like an automatic connect (never the password prompt); a subscription
/// and a disconnect wait in the window for the person (LinkRequestSheet).
@MainActor
enum DeepLinks {
    static let log = Logger(subsystem: "com.lesha19.KillSwitch", category: "link")

    static func open(_ url: URL) {
        switch DeepLink.parse(url) {
        case .failure(.notOurs):
            return
        case .failure(let rejection):
            // the link itself is not logged: it may carry a subscription key
            log.notice("killswitch:// link ignored: \(String(describing: rejection), privacy: .public)")
        case .success(let link):
            log.notice("killswitch:// link: \(link.logName, privacy: .private(mask: .hash))")
            Task { await handle(link) }
        }
    }

    private static func handle(_ link: DeepLink) async {
        if case .show(let route) = link {
            Router.shared.go(route)
            return
        }
        guard let objects = try? await ShortcutTarget.ready() else {
            log.notice("killswitch:// link ignored: the app is still starting")
            return
        }
        let (control, client) = objects
        guard Router.shared.linkRequest == nil else {
            log.notice("killswitch:// link ignored: another one waits for an answer")
            return
        }
        perform(DeepLink.plan(link, status: control.status(client), busy: control.busy, coreConfigured: control.coreConfigured),
                control: control, client: client)
    }

    static func perform(_ plan: DeepLink.Plan, control: KillSwitchControl, client: VPNClient) {
        switch plan {
        case .show(let route):
            Router.shared.go(route)
        case .run(let command):
            switch command {
            case .connect: Task { _ = await control.coreOnAutomatically() }
            case .disconnect: control.coreOff()
            default: log.fault("killswitch:// link: \(String(describing: command), privacy: .public) is not a link command")
            }
        case .add(let subscription):
            Task { await client.setURL(subscription.url) }
        case .confirm(let confirmation):
            Router.shared.linkRequest = confirmation
            Router.shared.go(.window)
        case .done:
            break
        case .refused:
            // the main screen says what stands in the way
            Router.shared.go(.section(.home))
        }
    }
}

/// The question of a `killswitch://add` or `disconnect` link. No button answers Return: a link
/// opened while the person types must not be confirmed by the next keystroke.
struct LinkRequestSheet: ViewModifier {
    @Bindable private var router = Router.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { router.linkRequest != nil }, set: { if !$0 { router.linkRequest = nil } })) {
            if let request = router.linkRequest { LinkRequestView(request: request) }
        }
    }
}

private struct LinkRequestView: View {
    let request: DeepLink.Confirmation

    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @State private var adding = false
    /// The client's error is shown only for an «Добавить» from this sheet, not an older one.
    @State private var tried = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch request {
            case .add(let subscription): add(subscription)
            case .disconnect: disconnect
            }
            Text("Об этом попросила ссылка killswitch:// с сайта или из другой программы. Если это не ты, нажми «Отмена».")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if tried, let error = client.lastError { InlineError(error: error) }
            HStack {
                Spacer()
                Button("Отмена") { close() }.keyboardShortcut(.cancelAction)
                confirmButton
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder private func add(_ subscription: DeepLink.Subscription) -> some View {
        Text("Добавить подписку?").font(.headline).accessibilityAddTraits(.isHeader)
        LabeledContent("Адрес") { Text(subscription.host).font(.title3.bold()).textSelection(.enabled) }
        LabeledContent("Ссылка") { Text(subscription.masked).monospaced().lineLimit(1) }
        Text("Добавляй, только если этот адрес — твоего провайдера.")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        if client.hasURL {
            Text("Она заменит текущую подписку.").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var disconnect: some View {
        Text("Отключить VPN?").font(.headline).accessibilityAddTraits(.isHeader)
        Text(DeepLink.disconnectWarning(status: control.status(client)))
            .font(.callout).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var confirmButton: some View {
        switch request {
        case .add:
            Button(client.hasURL ? String(localized: "Заменить подписку") : String(localized: "Добавить"), action: confirm)
                .disabled(adding)
        case .disconnect:
            Button("Отключить", role: .destructive, action: confirm)
        }
    }

    private func confirm() {
        let plan = DeepLink.confirmed(request, status: control.status(client), busy: control.busy)
        guard case .add(let subscription) = plan else {
            DeepLinks.perform(plan, control: control, client: client)
            close()
            return
        }
        // through the same checks as a link typed in Settings; the sheet stays for an error
        adding = true
        tried = true
        Task {
            await client.setURL(subscription.url)
            adding = false
            if client.lastError == nil { close() }
        }
    }

    private func close() { Router.shared.linkRequest = nil }
}
