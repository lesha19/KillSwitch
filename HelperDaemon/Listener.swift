import Foundation
import os

enum Log {
    static let daemon = Logger(subsystem: HelperIdentity.helperIdentifier, category: "daemon")
}

/// Accepts a connection only for our app or our `killswitch` tool (ADR 0025): the system checks every message against the
/// requirement with the peer's audit token (not its PID) and invalidates the connection otherwise.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(HelperIdentity.clientRequirement)
        connection.exportedInterface = HelperIdentity.interface()
        connection.exportedObject = Endpoint(uid: connection.effectiveUserIdentifier)
        connection.invalidationHandler = { Log.daemon.info("connection closed") }
        connection.resume()
        return true
    }
}

/// One per connection. Each method only builds its HelperCommand; Executor checks and runs it.
final class Endpoint: NSObject, HelperProtocol, Sendable {
    /// The connecting user (from the audit token): the one install.sh lets run the passwordless commands.
    let uid: uid_t

    init(uid: uid_t) { self.uid = uid }

    typealias Reply = @Sendable (Int32, String, String) -> Void

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }

    func state(reply: @escaping Reply) { Executor.perform(.state, caller: uid, reply: reply) }
    func probe(reply: @escaping Reply) { Executor.perform(.probe, caller: uid, reply: reply) }
    func protectionOn(reply: @escaping Reply) { Executor.perform(.protectionOn, caller: uid, reply: reply) }
    func netRestore(reply: @escaping Reply) { Executor.perform(.netRestore, caller: uid, reply: reply) }
    func coreState(reply: @escaping Reply) { Executor.perform(.coreState, caller: uid, reply: reply) }
    func coreOn(reply: @escaping Reply) { Executor.perform(.coreOn, caller: uid, reply: reply) }
    func coreOff(reply: @escaping Reply) { Executor.perform(.coreOff, caller: uid, reply: reply) }
    func coreRestart(reply: @escaping Reply) { Executor.perform(.coreRestart, caller: uid, reply: reply) }
    func coreProxies(reply: @escaping Reply) { Executor.perform(.coreProxies, caller: uid, reply: reply) }
    func coreTraffic(reply: @escaping Reply) { Executor.perform(.coreTraffic, caller: uid, reply: reply) }
    func coreConnections(reply: @escaping Reply) { Executor.perform(.coreConnections, caller: uid, reply: reply) }
    func coreSelect(group: String, proxy: String, reply: @escaping Reply) {
        Executor.perform(.coreSelect(group: group, proxy: proxy), caller: uid, reply: reply)
    }
    func coreDelay(name: String, reply: @escaping Reply) { Executor.perform(.coreDelay(name), caller: uid, reply: reply) }
    func coreRefresh(profile: FileHandle, reply: @escaping Reply) {
        Executor.perform(.coreRefresh(profile: Executor.profilePlaceholder), profile: profile, caller: uid, reply: reply)
    }
    func diagReport(output: FileHandle, reply: @escaping Reply) {
        // the journal holds every user's connections: not for whoever else is logged in
        guard DiagReport.mayCollect(caller: uid, console: DiagReport.consoleUser(), installer: DiagReport.installingUser()) else {
            try? output.close()
            reply(HelperReply.refused, "", "Отчёт может собрать только пользователь, который сейчас работает за этим Mac")
            return
        }
        Executor.perform(.diagReport(directory: Executor.profilePlaceholder, uid: uid), output: output, caller: uid, reply: reply)
    }

    func repair(authorization: Data, reply: @escaping Reply) {
        Executor.perform(.repair, authorization: authorization, caller: uid, reply: reply)
    }
    func protectionOff(authorization: Data, reply: @escaping Reply) {
        Executor.perform(.protectionOff, authorization: authorization, caller: uid, reply: reply)
    }
    func pause(minutes: Int, authorization: Data, reply: @escaping Reply) {
        Executor.perform(.pause(minutes: minutes), authorization: authorization, caller: uid, reply: reply)
    }
    func setSwitch(key: String, on: Bool, authorization: Data, reply: @escaping Reply) {
        Executor.perform(.setSwitch(key, on), authorization: authorization, caller: uid, reply: reply)
    }
    func setSplitApps(names: [String], authorization: Data, reply: @escaping Reply) {
        Executor.perform(.setSplitApps(names), authorization: authorization, caller: uid, reply: reply)
    }
    func setMultihop(entry: String?, authorization: Data, reply: @escaping Reply) {
        Executor.perform(.setMultihop(entry), authorization: authorization, caller: uid, reply: reply)
    }
    func setDoH(url: String?, authorization: Data, reply: @escaping Reply) {
        Executor.perform(.setDoH(url), authorization: authorization, caller: uid, reply: reply)
    }
    func setCore(name: String, authorization: Data, reply: @escaping Reply) {
        guard let core = CoreChoice(rawValue: name) else {
            reply(HelperReply.refused, "", "usage: ks set core xray|mihomo")
            return
        }
        Executor.perform(.setCore(core), authorization: authorization, caller: uid, reply: reply)
    }
    func setMTU(value: Int, authorization: Data, reply: @escaping Reply) {
        Executor.perform(.setMTU(value == 0 ? nil : value), authorization: authorization, caller: uid, reply: reply)
    }
    func allow(address: String, authorization: Data, reply: @escaping Reply) {
        Executor.perform(.allow(address), authorization: authorization, caller: uid, reply: reply)
    }
    func unallow(address: String, authorization: Data, reply: @escaping Reply) {
        Executor.perform(.unallow(address), authorization: authorization, caller: uid, reply: reply)
    }
    func serverAdd(address: String, authorization: Data, reply: @escaping Reply) {
        Executor.perform(.serverAdd(address), authorization: authorization, caller: uid, reply: reply)
    }
    func serverRemove(address: String, authorization: Data, reply: @escaping Reply) {
        Executor.perform(.serverRemove(address), authorization: authorization, caller: uid, reply: reply)
    }
    func coreImport(profile: FileHandle, authorization: Data, reply: @escaping Reply) {
        Executor.perform(.coreImport(profile: Executor.profilePlaceholder), authorization: authorization, profile: profile,
                         caller: uid, reply: reply)
    }
    func install(servers: [String], authorization: Data, reply: @escaping Reply) {
        // the sudoers entry goes to whoever connected, not to a name the app sends
        let user = uid == 0 ? "" : Executor.userName(uid) ?? ""
        Executor.perform(.install(user: user, servers: servers), authorization: authorization, caller: uid, reply: reply)
    }
    func uninstall(authorization: Data, reply: @escaping Reply) {
        Executor.perform(.uninstall, authorization: authorization, caller: uid, reply: reply)
    }
    func upgrade(reply: @escaping Reply) { Executor.perform(.upgrade, caller: uid, reply: reply) }
}
