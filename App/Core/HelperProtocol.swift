import Foundation

/// Names shared by the app and the privileged daemon (ADR 0010).
enum HelperIdentity {
    static let machService = "com.lesha19.KillSwitch.helper"
    /// In the app at Contents/Library/LaunchDaemons, registered with SMAppService.daemon(plistName:).
    static let plistName = "com.lesha19.KillSwitch.helper.plist"
    /// In the app at Contents/MacOS (the plist's BundleProgram).
    static let executable = "KillSwitchHelper"
    static let team = "YR58655PJ7"
    static let appIdentifier = "com.lesha19.KillSwitch"
    static let helperIdentifier = "com.lesha19.KillSwitch.helper"
    /// `killswitch` in the app at Contents/Helpers (ADR 0025).
    static let cliIdentifier = "com.lesha19.KillSwitch.cli"

    /// Our app, signed by our team through Apple's CA (Developer ID or Apple Development). The
    /// bundle root runs install.sh from must be this, never the CLI.
    static let appRequirement = requirement("identifier \"\(appIdentifier)\"")
    /// Who may connect to the daemon: our app or our `killswitch` tool, same anchor and team.
    /// Checked by the system against the peer's audit token.
    static let clientRequirement = requirement("(identifier \"\(appIdentifier)\" or identifier \"\(cliIdentifier)\")")
    /// Who the app and the CLI talk to: our daemon, not something else that took the Mach name.
    static let daemonRequirement = requirement("identifier \"\(helperIdentifier)\"")

    private static func requirement(_ identity: String) -> String {
        "anchor apple generic and \(identity) and certificate leaf[subject.OU] = \"\(team)\""
    }
}

/// The daemon's XPC interface: one typed method per operation, no "run this". Replies carry ks's
/// exit status, stdout and stderr (or one of `HelperReply`'s own statuses). Methods that widen
/// the rules take the external form of an authorization holding `HelperRight.name`.
/// Profiles come as file handles opened by the app, so the root side never opens a user's path.
@objc protocol HelperProtocol {
    /// The daemon's build, `CFBundleVersion` of the app it came with.
    func version(reply: @escaping @Sendable (String) -> Void)

    func state(reply: @escaping @Sendable (Int32, String, String) -> Void)
    func probe(reply: @escaping @Sendable (Int32, String, String) -> Void)
    func protectionOn(reply: @escaping @Sendable (Int32, String, String) -> Void)
    func netRestore(reply: @escaping @Sendable (Int32, String, String) -> Void)
    func coreState(reply: @escaping @Sendable (Int32, String, String) -> Void)
    func coreOn(reply: @escaping @Sendable (Int32, String, String) -> Void)
    func coreOff(reply: @escaping @Sendable (Int32, String, String) -> Void)
    func coreRestart(reply: @escaping @Sendable (Int32, String, String) -> Void)
    func coreProxies(reply: @escaping @Sendable (Int32, String, String) -> Void)
    func coreTraffic(reply: @escaping @Sendable (Int32, String, String) -> Void)
    func coreConnections(reply: @escaping @Sendable (Int32, String, String) -> Void)
    func coreSelect(group: String, proxy: String, reply: @escaping @Sendable (Int32, String, String) -> Void)
    func coreDelay(name: String, reply: @escaping @Sendable (Int32, String, String) -> Void)
    func coreRefresh(profile: FileHandle, reply: @escaping @Sendable (Int32, String, String) -> Void)
    /// «Собрать отчёт» (ADR 0021): the archive is written into `output`, a file the app opened.
    func diagReport(output: FileHandle, reply: @escaping @Sendable (Int32, String, String) -> Void)

    func protectionOff(authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    func pause(minutes: Int, authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    func setSwitch(key: String, on: Bool, authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    func setSplitApps(names: [String], authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    func setMultihop(entry: String?, authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    /// ADR 0031: the own DNS-over-HTTPS server; nil clears it (HelperCommand.setDoH).
    func setDoH(url: String?, authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    /// ADR 0033: own addresses of sites, "name=IPv4" each; [] clears them (HelperCommand.setHosts).
    func setHosts(entries: [String], authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    func setCore(name: String, authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    /// 0: «Авто».
    func setMTU(value: Int, authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    func allow(address: String, authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    func unallow(address: String, authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    func serverAdd(address: String, authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    func serverRemove(address: String, authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    func coreImport(profile: FileHandle, authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    func install(servers: [String], authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    func uninstall(authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    /// #17: damaged settings files back to the defaults (HelperCommand.repair).
    func repair(authorization: Data, reply: @escaping @Sendable (Int32, String, String) -> Void)
    /// ADR 0012: the bundle's helper over the installed one, without the right (HelperCommand.upgrade).
    func upgrade(reply: @escaping @Sendable (Int32, String, String) -> Void)
}

extension HelperIdentity {
    /// The interface both sides use; string lists are decoded as arrays of strings only.
    static func interface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: HelperProtocol.self)
        let strings = NSSet(objects: NSArray.self, NSString.self) as! Set<AnyHashable>
        for selector in [#selector(HelperProtocol.setSplitApps(names:authorization:reply:)),
                         #selector(HelperProtocol.setHosts(entries:authorization:reply:)),
                         #selector(HelperProtocol.install(servers:authorization:reply:))] {
            interface.setClasses(strings, for: selector, argumentIndex: 0, ofReply: false)
        }
        return interface
    }
}

/// One answer of the daemon.
struct HelperReply: Equatable, Sendable {
    var status: Int32
    var stdout: String
    var stderr: String

    /// The authorization was missing, expired or not for `HelperRight.name`: ask again.
    static let notAuthorized: Int32 = -2
    /// A value the daemon does not take (HelperCommand.isValid).
    static let refused: Int32 = -3
    /// The daemon could not run the program (missing, not root-owned, bundle not intact).
    static let failedToRun: Int32 = -4

    var needsAuthorization: Bool { status == Self.notAuthorized }

    /// What `sudo -n ks …` used to give the app: stdout and stderr together, or with
    /// `separateStderr` stdout on success (JSON) and stderr on failure. Trimmed.
    func text(separateStderr: Bool) -> String {
        let raw = separateStderr ? (status == 0 ? stdout : stderr)
            : [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                .joined(separator: "\n")
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A failure as the app shows it. install.sh and uninstall.sh say why on stderr (their stdout is
    /// progress), as the password prompt's path shows it; a ks command keeps both. Empty without text.
    func failureText(_ program: HelperCommand.Program) -> String {
        let both = text(separateStderr: false)
        let errors = program == .ks ? both : text(separateStderr: true)
        return errors.isEmpty ? both : errors
    }
}
