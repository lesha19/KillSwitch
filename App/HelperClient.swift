import Foundation
import Security
import ServiceManagement
import os

/// The app's side of the privileged daemon (ADR 0010): its SMAppService registration, the XPC
/// connection (to our signed daemon only) and the authorization right. Commands that widen the
/// rules ask macOS for `HelperRight.name` first: its dialog at most once every five minutes.
@MainActor
final class HelperClient {
    private let service = SMAppService.daemon(plistName: HelperIdentity.plistName)
    private var connection: NSXPCConnection?
    private let authorization = AppAuthorization()

    var availability: HelperService.Availability {
        HelperService.availability(service.status, daemonBundled: Self.daemonBundled)
    }

    static let log = Logger(subsystem: "com.lesha19.KillSwitch", category: "helper")

    /// The daemon's launchd plist is in this app (Contents/Library/LaunchDaemons).
    private static let daemonBundled = FileManager.default.fileExists(
        atPath: Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchDaemons/\(HelperIdentity.plistName)").path)

    /// Registers the daemon; macOS then wants it switched on in Login Items (`needsApproval`).
    @discardableResult
    func register() -> HelperService.Availability {
        let before = service.status.rawValue
        do {
            try service.register()
            Self.log.notice("daemon register: status \(before, privacy: .public) -> \(self.service.status.rawValue, privacy: .public)")
        } catch {
            // "Operation not permitted" while it waits for approval: the status says the rest
            Self.log.error("daemon register failed (status \(before, privacy: .public) -> \(self.service.status.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
        return availability
    }

    func unregister() async { try? await service.unregister() }

    static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    enum Outcome: Equatable { case reply(HelperReply), cancelled, unreachable }

    /// Runs `command` in the daemon. A command behind the right asks for it first, unless not
    /// `interactive` (a timer): then it answers `notAuthorized` without a dialog. `unreachable`:
    /// the daemon did not answer (not running, not ours, an older one); the caller falls back.
    func send(_ command: HelperCommand, interactive: Bool) async -> Outcome {
        guard command.needsAuthorization else {
            return await call(command, authorization: nil).map(Outcome.reply) ?? .unreachable
        }
        // macOS's dialog for the right only for a user action (AdminGate)
        let what: String = switch command {
        case .install: "install.sh"
        case .uninstall: "uninstall.sh"
        default: AdminGate.reason([["ks"] + command.arguments])
        }
        guard AdminGate.permit(.init(reason: "right for " + what, userInitiated: interactive)) else {
            return .reply(HelperReply(status: HelperReply.notAuthorized, stdout: "", stderr: ""))
        }
        for _ in 0..<2 {
            let form: Data
            switch await authorization.obtain() {
            case .granted(let data): form = data
            case .cancelled: return .cancelled
            case .failed(let message): return .reply(HelperReply(status: HelperReply.notAuthorized, stdout: "", stderr: message))
            }
            guard let reply = await call(command, authorization: form) else { return .unreachable }
            // expired between the two checks: once more, with the dialog if it is due
            if !reply.needsAuthorization { return .reply(reply) }
        }
        return .reply(HelperReply(status: HelperReply.notAuthorized, stdout: "", stderr: "Нет подтверждения администратора"))
    }

    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: HelperIdentity.machService, options: .privileged)
        connection.remoteObjectInterface = HelperIdentity.interface()
        // only our daemon: anything else holding the name is refused by the system
        connection.setCodeSigningRequirement(HelperIdentity.daemonRequirement)
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    /// The running daemon's build (CFBundleVersion of the app it came with); nil if it does not answer.
    func daemonBuild() async -> String? {
        let connection = connect()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = OnceValue(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in once.resume(nil) }
            guard let helper = proxy as? HelperProtocol else { once.resume(nil); return }
            helper.version { @Sendable build in once.resume(build) }
        }
    }

    /// nil: no answer (connection refused, invalidated or interrupted).
    private func call(_ command: HelperCommand, authorization auth: Data?) async -> HelperReply? {
        let connection = connect()
        var profile: FileHandle?
        var report: (handle: FileHandle, path: String)?
        switch command {
        case .coreImport(let path), .coreRefresh(let path):
            // opened here, as the user: the daemon never opens a user's path as root
            guard let handle = FileHandle(forReadingAtPath: path) else {
                return HelperReply(status: HelperReply.failedToRun, stdout: "", stderr: "Не удалось открыть профиль")
            }
            profile = handle
        case .diagReport(let directory, _):
            // the file is the user's, made here; the daemon only writes into the open handle
            let path = directory + "/" + DiagReport.fileName(for: Date())
            guard FileManager.default.createFile(atPath: path, contents: nil),
                  let handle = FileHandle(forWritingAtPath: path) else {
                return HelperReply(status: HelperReply.failedToRun, stdout: "", stderr: "Не удалось создать файл отчёта")
            }
            report = (handle, path)
        default:
            break
        }
        defer { try? profile?.close(); try? report?.handle.close() }
        if let report {
            let reply = await withCheckedContinuation { (continuation: CheckedContinuation<HelperReply?, Never>) in
                let once = Once(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in once.resume(nil) }
                guard let helper = proxy as? HelperProtocol else { once.resume(nil); return }
                helper.diagReport(output: report.handle) { @Sendable in once.resume(HelperReply(status: $0, stdout: $1, stderr: $2)) }
            }
            // ks prints the archive's path: the app's file stands for it
            guard let reply, reply.status == 0 else { try? FileManager.default.removeItem(atPath: report.path); return reply }
            return HelperReply(status: 0, stdout: report.path, stderr: "")
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<HelperReply?, Never>) in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in once.resume(nil) }
            guard let helper = proxy as? HelperProtocol else { once.resume(nil); return }
            let reply: @Sendable (Int32, String, String) -> Void = { once.resume(HelperReply(status: $0, stdout: $1, stderr: $2)) }
            let form = auth ?? Data()
            switch command {
            case .state: helper.state(reply: reply)
            case .probe: helper.probe(reply: reply)
            case .protectionOn: helper.protectionOn(reply: reply)
            case .netRestore: helper.netRestore(reply: reply)
            case .coreState: helper.coreState(reply: reply)
            case .coreOn: helper.coreOn(reply: reply)
            case .coreOff: helper.coreOff(reply: reply)
            case .coreProxies: helper.coreProxies(reply: reply)
            case .coreTraffic: helper.coreTraffic(reply: reply)
            case .coreConnections: helper.coreConnections(reply: reply)
            case .coreSelect(let group, let proxy): helper.coreSelect(group: group, proxy: proxy, reply: reply)
            case .coreDelay(let name): helper.coreDelay(name: name, reply: reply)
            case .coreRefresh: helper.coreRefresh(profile: profile!, reply: reply)
            case .diagReport: once.resume(nil)   // answered above
            case .protectionOff: helper.protectionOff(authorization: form, reply: reply)
            case .repair: helper.repair(authorization: form, reply: reply)
            case .pause(let minutes): helper.pause(minutes: minutes, authorization: form, reply: reply)
            case .setSwitch(let key, let on): helper.setSwitch(key: key, on: on, authorization: form, reply: reply)
            case .setSplitApps(let names): helper.setSplitApps(names: names, authorization: form, reply: reply)
            case .setMultihop(let entry): helper.setMultihop(entry: entry, authorization: form, reply: reply)
            case .setDoH(let url): helper.setDoH(url: url, authorization: form, reply: reply)
            case .setCore(let core): helper.setCore(name: core.rawValue, authorization: form, reply: reply)
            case .allow(let address): helper.allow(address: address, authorization: form, reply: reply)
            case .unallow(let address): helper.unallow(address: address, authorization: form, reply: reply)
            case .serverAdd(let address): helper.serverAdd(address: address, authorization: form, reply: reply)
            case .serverRemove(let address): helper.serverRemove(address: address, authorization: form, reply: reply)
            case .coreImport: helper.coreImport(profile: profile!, authorization: form, reply: reply)
            // the user is the one the daemon sees connecting
            case .install(_, let servers): helper.install(servers: servers, authorization: form, reply: reply)
            case .uninstall: helper.uninstall(authorization: form, reply: reply)
            case .upgrade: helper.upgrade(reply: reply)
            }
        }
    }
}

/// Resumes a continuation once: the reply and the connection's error handler may both arrive.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HelperReply?, Never>?

    init(_ continuation: CheckedContinuation<HelperReply?, Never>) { self.continuation = continuation }

    func resume(_ value: HelperReply?) {
        let pending = lock.withLock { () -> CheckedContinuation<HelperReply?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// The same for the daemon's version.
private final class OnceValue: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

    func resume(_ value: String?) {
        let pending = lock.withLock { () -> CheckedContinuation<String?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
