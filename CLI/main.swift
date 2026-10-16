import Foundation

// killswitch (ADR 0025): KillSwitch.app/Contents/Helpers/killswitch, a client of the privileged
// daemon over the app's own XPC interface. Arguments and output: App/Core/CLI.swift.

func printError(_ text: String) {
    FileHandle.standardError.write(Data(("killswitch: " + text + "\n").utf8))
}

func finish(_ code: CLI.Exit) -> Never { exit(code.rawValue) }

/// One connection to our daemon only (the same requirement as the app's).
final class DaemonConnection: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let authorization = AppAuthorization()

    init() {
        connection = NSXPCConnection(machServiceName: HelperIdentity.machService, options: .privileged)
        connection.remoteObjectInterface = HelperIdentity.interface()
        connection.setCodeSigningRequirement(HelperIdentity.daemonRequirement)
        connection.resume()
    }

    /// nil: no answer (not running, not approved in Login Items, not ours).
    private func call(_ command: HelperCommand, authorization form: Data) -> HelperReply? {
        let done = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() }
        guard let helper = proxy as? HelperProtocol else { return nil }
        let reply: @Sendable (Int32, String, String) -> Void = { status, out, err in
            box.set(HelperReply(status: status, stdout: out, stderr: err))
            done.signal()
        }
        switch command {
        case .state: helper.state(reply: reply)
        case .coreState: helper.coreState(reply: reply)
        case .coreProxies: helper.coreProxies(reply: reply)
        case .coreOn: helper.coreOn(reply: reply)
        case .coreOff: helper.coreOff(reply: reply)
        case .protectionOn: helper.protectionOn(reply: reply)
        case .protectionOff: helper.protectionOff(authorization: form, reply: reply)
        case .pause(let minutes): helper.pause(minutes: minutes, authorization: form, reply: reply)
        case .coreSelect(let group, let proxy): helper.coreSelect(group: group, proxy: proxy, reply: reply)
        default: return nil   // only what ADR 0025 lists
        }
        // ks waits for the core at most a few seconds; a stuck daemon must not hang a script
        guard done.wait(timeout: .now() + 120) == .success else { return nil }
        return box.value
    }

    /// The daemon's answer, or the exit when there is none. Behind the right (the same test as
    /// the app's, HelperCommand.needsAuthorization) macOS's dialog asks first.
    func send(_ command: HelperCommand) async -> HelperReply {
        guard command.needsAuthorization else {
            guard let reply = call(command, authorization: Data()) else { unreachable() }
            return reply
        }
        for _ in 0..<2 {
            switch await authorization.obtain() {
            case .granted(let form):
                guard let reply = call(command, authorization: form) else { unreachable() }
                // expired between the two checks: once more
                if !reply.needsAuthorization { return reply }
            case .cancelled:
                printError("cancelled")
                finish(.notAuthorized)
            case .failed(let message):
                printError(message)
                finish(.notAuthorized)
            }
        }
        printError("no administrator's confirmation")
        finish(.notAuthorized)
    }

    /// Output of a read, or the exit with the daemon's text.
    func read(_ command: HelperCommand) async -> String {
        let reply = await send(command)
        guard reply.status == 0 else { fail(reply) }
        return reply.stdout
    }

    private func unreachable() -> Never {
        printError("the KillSwitch service does not answer: open KillSwitch and check that it is allowed "
            + "in System Settings > General > Login Items")
        finish(.unavailable)
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: HelperReply?
    var value: HelperReply? { lock.withLock { reply } }
    func set(_ value: HelperReply) { lock.withLock { reply = value } }
}

func fail(_ reply: HelperReply) -> Never {
    let text = reply.failureText(.ks)
    printError(text.isEmpty ? "failed (status \(reply.status))" : text)
    finish(CLI.exit(for: reply))
}

func proxies(_ daemon: DaemonConnection) async -> CoreProxies? {
    CLI.proxies(await daemon.read(.coreProxies), appDefaults: UserDefaults(suiteName: CLI.appDefaultsSuite))
}

/// Whose profile the helper runs (the app's, ADR 0036).
let running = UserDefaults(suiteName: CLI.appDefaultsSuite)?.string(forKey: CLI.activeKey) ?? ServerID.own

/// Every subscription's servers: the running one's from the core, the others as the app listed them.
func blocks(_ proxies: CoreProxies, running: String) -> [ServerPicker.Block] {
    CLI.blocks(UserDefaults(suiteName: CLI.appDefaultsSuite)?.data(forKey: CLI.serversKey), running: running, proxies: proxies)
}

let command: CLI.Command
switch CLI.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed): command = parsed
case .failure(let error):
    printError(error.message)
    FileHandle.standardError.write(Data((CLI.usage + "\n").utf8))
    finish(.usage)
}

switch command {
case .help:
    print(CLI.usage)
case .version:
    print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
case .status(let json):
    let daemon = DaemonConnection()
    let state = await daemon.read(.state)
    let core = await daemon.read(.coreState)
    let on = core.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("on")
    let list = on ? await proxies(daemon) : nil
    let status = CLI.Status(state: state, coreState: core, proxies: list,
                            subscription: list.flatMap { CLI.title(of: running, in: blocks($0, running: running)) })
    print(json ? CLI.json(status) : CLI.text(status))
case .serverList(let json):
    let daemon = DaemonConnection()
    guard await daemon.read(.coreState).hasPrefix("on"), let list = await proxies(daemon) else {
        printError("the VPN is not connected: killswitch connect")
        finish(.failed)
    }
    let current = ServerPicker.selected(list).map { ServerID(subscription: running, name: $0) }
    let all = blocks(list, running: running)
    print(json ? CLI.json(all, current: current) : CLI.text(all, current: current))
case .serverSelect(let name):
    let daemon = DaemonConnection()
    guard await daemon.read(.coreState).hasPrefix("on"), let list = await proxies(daemon) else {
        printError("the VPN is not connected: a server can be chosen after killswitch connect")
        finish(.failed)
    }
    let all = blocks(list, running: running)
    switch CLI.selection(name, in: all, running: running) {
    case .success(let entry):
        guard let steps = CLI.steps(entry, running: running, proxies: list) else {
            // the daemon runs one subscription; handing it another one's profile is the app's (VPNClient)
            printError("\(CLI.label(entry, in: all)) is a server of another subscription: choose it in KillSwitch")
            finish(.failed)
        }
        for step in steps {
            let reply = await daemon.send(.coreSelect(group: step.group, proxy: step.proxy))
            if reply.status != 0 { fail(reply) }
        }
    case .failure(.notFound):
        printError("no such server: \(name) (see killswitch server list)")
        finish(.failed)
    case .failure(.ambiguous(let names)):
        printError("several servers match: " + names.joined(separator: ", "))
        finish(.failed)
    case .failure(.sameTitle(let title)):
        printError("several subscriptions are called \(title): choose the server in KillSwitch")
        finish(.failed)
    }
case .connect, .disconnect, .protection, .pause:
    guard let daemonCommand = command.daemonCommand else { finish(.failed) }
    let reply = await DaemonConnection().send(daemonCommand)
    if reply.status != 0 { fail(reply) }
}
finish(.ok)
