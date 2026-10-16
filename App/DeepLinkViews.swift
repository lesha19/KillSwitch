import AppKit
import OSLog
import SwiftUI

/// `killswitch://` links (#23, ADR 0029): what DeepLink decided, done by the app. A section opens
/// the window; «connect» runs like an automatic connect (never the password prompt); a subscription
/// and a disconnect wait in the window for the person (LinkRequestSheet).
@MainActor
enum DeepLinks {
    static let log = Logger(subsystem: "com.lesha19.KillSwitch", category: "link")
    private static var throttle = DeepLink.Throttle()
    private static var watchingActivity = false

    static func open(_ url: URL) {
        switch DeepLink.parse(url) {
        case .failure(.notOurs):
            return
        case .failure(let rejection):
            // the link itself is not logged: it may carry a subscription key
            log.notice("killswitch:// link ignored: \(String(describing: rejection), privacy: .public)")
        case .success(let link):
            guard !link.isPaced || throttle.allows(at: ProcessInfo.processInfo.systemUptime) else {
                log.notice("killswitch:// link ignored: \(link.logName, privacy: .private) came less than 2 s after the last one")
                return
            }
            if case .add = link {
                log.notice("killswitch:// link: \(link.logName, privacy: .private)")   // the host
            } else {
                log.notice("killswitch:// link: \(link.logName, privacy: .public)")
            }
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
        let router = Router.shared
        dropIfStale(resignedActive: false)
        guard router.linkRequest == nil else {
            log.notice("killswitch:// link ignored: another one waits for an answer")
            router.go(.window)   // where that question is
            return
        }
        perform(DeepLink.plan(link, status: control.status(client), busy: control.busy, coreConfigured: control.coreConfigured,
                              protectionOn: protectionOn(control)),
                control: control)
    }

    /// Protection blocks now: on, not paused, not standing by next to another VPN (ADR 0018).
    static func protectionOn(_ control: KillSwitchControl) -> Bool {
        control.state == .on && !control.protectionStandby
    }

    static func perform(_ plan: DeepLink.Plan, control: KillSwitchControl) {
        switch plan {
        case .show(let route):
            Router.shared.go(route)
        case .run(let command):
            switch DeepLink.action(for: command) {
            case .connectAutomatically: Task { _ = await control.coreOnAutomatically() }
            case .disconnect: control.coreOff()
            case nil: log.fault("killswitch:// link: \(String(describing: command), privacy: .public) is not a link command")
            }
        case .add:
            // only LinkRequestView stores a subscription, after «Добавить»
            assertionFailure("a link's subscription is added only from its sheet")
            log.fault("killswitch:// link: a subscription reached perform")
        case .confirm(let confirmation):
            ask(confirmation)
        case .done(let text):
            log.notice("killswitch:// link done: \(text, privacy: .public)")
        case .refused(let text):
            log.notice("killswitch:// link refused: \(text, privacy: .public)")
            // the main screen shows the state that stands in the way
            Router.shared.go(.section(.home))
        }
    }

    private static func ask(_ confirmation: DeepLink.Confirmation) {
        let router = Router.shared
        guard !router.onboarding else {
            // a sheet cannot show over «Начало работы»: it would pop up later, out of context
            log.notice("killswitch:// link ignored: «Начало работы» is open")
            router.go(.window)
            return
        }
        watchActivity()
        let request = DeepLink.Request(confirmation, at: ProcessInfo.processInfo.systemUptime)
        router.linkRequest = request
        router.go(.window)
        Task {
            try? await Task.sleep(for: .seconds(DeepLink.Request.timeout + 1))
            dropIfStale(resignedActive: false)
        }
    }

    /// A question nobody saw before the app lost the front, or older than its timeout, is dropped.
    static func dropIfStale(resignedActive: Bool) {
        let router = Router.shared
        guard let request = router.linkRequest,
              request.isStale(now: ProcessInfo.processInfo.systemUptime, resignedActive: resignedActive, busy: router.linkBusy) else { return }
        log.notice("killswitch:// link question dropped: not answered")
        router.linkRequest = nil
    }

    private static func watchActivity() {
        guard !watchingActivity else { return }
        watchingActivity = true
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { dropIfStale(resignedActive: true) }
        }
    }
}

/// The question of a `killswitch://add` or `disconnect` link. No button answers Return: a link
/// opened while the person types must not be confirmed by the next keystroke.
struct LinkRequestSheet: ViewModifier {
    @Bindable private var router = Router.shared

    func body(content: Content) -> some View {
        // while its subscription is fetched the sheet is not dismissed (Esc): a person who thinks
        // they cancelled must not get a replace; only an update's quit (dropSheets) takes it away,
        // and then the fetch is not kept (setURL's stillWanted)
        content.sheet(isPresented: Binding(get: { router.linkRequest != nil },
                                           set: { if !$0, !router.linkBusy { router.linkRequest = nil } })) {
            if let request = router.linkRequest { LinkRequestView(request: request) }
        }
    }
}

private struct LinkRequestView: View {
    let request: DeepLink.Request

    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @State private var adding = false
    /// The client's error is shown only for an «Добавить» from this sheet, not an older one.
    @State private var tried = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch request.confirmation {
            case .add(let subscription): add(subscription)
            case .disconnect: disconnect
            }
            Text("Об этом попросила ссылка killswitch:// с сайта или из другой программы. Если это не ты, нажми «Отмена».")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if tried, let error = client.lastError {
                InlineError(error: error)
            }
            HStack {
                if adding { ProgressView().controlSize(.small) }
                Spacer()
                // not while the new link is fetched
                Button("Отмена") { close() }.keyboardShortcut(.cancelAction).disabled(adding)
                confirmButton
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(adding)
        .onAppear {
            if Router.shared.linkRequest?.id == request.id { Router.shared.linkRequest?.shown = true }
        }
    }

    @ViewBuilder private func add(_ subscription: DeepLink.Subscription) -> some View {
        Text("Добавить подписку?").font(.headline).accessibilityAddTraits(.isHeader)
        LabeledContent("Адрес") {
            Text(subscription.host).font(.title3.bold()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        LabeledContent("Ссылка") { Text(subscription.masked).monospaced().lineLimit(1).truncationMode(.middle) }
        Text("Добавляй, только если этот адрес — твоего провайдера.")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        Text("KillSwitch сразу обратится к этому адресу: его владелец увидит IP-адрес и идентификатор этого Mac.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if client.hasURL {
            Text("Она добавится к твоим подпискам, они останутся как есть.").font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var disconnect: some View {
        Text("Отключить VPN?").font(.headline).accessibilityAddTraits(.isHeader)
        Text("Защита останется включённой: интернет будет закрыт, пока VPN не подключится снова.")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var confirmButton: some View {
        switch request.confirmation {
        case .add:
            Button("Добавить", action: confirm).disabled(adding)
        case .disconnect:
            Button("Отключить", role: .destructive, action: confirm)
        }
    }

    private func confirm() {
        let plan = DeepLink.confirmed(request.confirmation, status: control.status(client), busy: control.busy,
                                      protectionOn: DeepLinks.protectionOn(control))
        guard case .add(let subscription) = plan else {
            DeepLinks.perform(plan, control: control)
            close()
            return
        }
        // through the same checks as a link typed in Settings; the sheet stays for an error
        adding = true
        tried = true
        Router.shared.linkBusy = true
        Task {
            await client.add(subscription.url)
            Router.shared.linkBusy = false
            adding = false
            if client.lastError == nil { close() }
        }
    }

    /// Only this request's sheet: a late answer must not close a newer question.
    private func close() {
        if Router.shared.linkRequest?.id == request.id { Router.shared.linkRequest = nil }
    }
}
