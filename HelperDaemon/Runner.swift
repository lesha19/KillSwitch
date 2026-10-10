import Foundation

/// Runs a checked command as root: `/Library/KillSwitch/ks` with an argument vector, or install.sh /
/// uninstall.sh from a verified copy of the app. No shell line is ever built.
enum Runner {
    static let directory = "/Library/KillSwitch"
    static let ks = directory + "/ks"

    static func run(_ command: HelperCommand) -> HelperReply {
        switch command.program {
        case .ks:
            // root runs it: it and its directory must be root's and writable by nobody else
            guard isRootOnly(directory, directory: true), isRootOnly(ks, directory: false) else {
                return HelperReply(status: HelperReply.failedToRun, stdout: "",
                                   stderr: "Служба KillSwitch не установлена или повреждена: «Восстановить службу…»")
            }
            return execute(ks, command.arguments)
        case .upgrade:
            return upgrade()
        case .install, .uninstall:
            guard let copy = verifiedCopy() else {
                return HelperReply(status: HelperReply.failedToRun, stdout: "",
                                   stderr: "Программа KillSwitch повреждена или подписана не нами: скачайте её заново")
            }
            defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
            let script = command.program == .install ? "install.sh" : "uninstall.sh"
            let path = copy.appendingPathComponent("Contents/Resources/Helper/\(script)").path
            return execute("/bin/bash", HelperCommand.scriptArguments(path, command.arguments))
        }
    }

    /// ADR 0012, no password: the code comes from the verified copy of our own bundle (the same
    /// signature this daemon runs under), and is put in place only if it is not older than the
    /// installed helper. install.sh --upgrade keeps the sudoers user and the protection state.
    private static func upgrade() -> HelperReply {
        guard let copy = verifiedCopy() else {
            return HelperReply(status: HelperReply.failedToRun, stdout: "",
                               stderr: "Программа KillSwitch повреждена или подписана не нами: скачайте её заново")
        }
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let helperDir = copy.appendingPathComponent("Contents/Resources/Helper")
        let installed = isRootOnly(directory, directory: true) && isRootOnly(ks, directory: false)
            ? FileManager.default.contents(atPath: ks) : nil
        let bundled = FileManager.default.contents(atPath: helperDir.appendingPathComponent("ks").path)
        switch HelperUpgrade.decide(installed: installed, bundled: bundled) {
        case .notInstalled:
            return HelperReply(status: HelperReply.failedToRun, stdout: "",
                               stderr: "Служба KillSwitch не установлена или повреждена: «Восстановить службу…»")
        case .downgrade:
            return HelperReply(status: HelperReply.refused, stdout: "",
                               stderr: "Эта версия KillSwitch старше установленной службы: обновите программу")
        case .current:
            return HelperReply(status: 0, stdout: "helper: current", stderr: "")
        case .upgrade:
            return execute("/bin/bash", HelperCommand.scriptArguments(helperDir.appendingPathComponent("install.sh").path,
                                                                      HelperCommand.upgrade.arguments))
        }
    }

    /// The app bundle this daemon belongs to: …/KillSwitch.app/Contents/MacOS/KillSwitchHelper.
    static func ownBundle() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard executable.lastPathComponent == HelperIdentity.executable,
              executable.deletingLastPathComponent().path.hasSuffix(".app/Contents/MacOS"),
              bundle.pathExtension == "app" else { return nil }
        return bundle
    }

    /// The bundle can be written by its user. Its copy in a root-only directory is checked and
    /// then used, so nothing can be swapped between the check and the run: every nested part and
    /// sealed resource (Helper/ included) intact and signed for our app by our team.
    private static func verifiedCopy() -> URL? {
        guard let bundle = ownBundle(), let dir = privateDirectory() else { return nil }
        let copy = dir.appendingPathComponent(bundle.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: bundle, to: copy)   // a clone on APFS
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        guard BundleSignature.isValid(copy, requirement: HelperIdentity.clientRequirement) else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        return copy
    }

    /// A fresh 0700 directory of root's (mkdtemp in root's own temporary directory).
    static func privateDirectory() -> URL? {
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("killswitch.XXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else { return nil }
        return URL(fileURLWithPath: String(cString: made), isDirectory: true)
    }

    /// Not a symlink, owned by root, not writable by group or others.
    private static func isRootOnly(_ path: String, directory: Bool) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { return false }
        return (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG)
    }

    private static func execute(_ program: String, _ arguments: [String]) -> HelperReply {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.environment = HelperCommand.environment   // nothing of the daemon's own (0.12.1)
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            return HelperReply(status: HelperReply.failedToRun, stdout: "", stderr: error.localizedDescription)
        }
        // both pipes read while it runs: install.sh and `core proxies` print more than a pipe holds
        let group = DispatchGroup()
        nonisolated(unsafe) var errData = Data()
        group.enter()
        DispatchQueue.global().async {
            errData = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return HelperReply(status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self))
    }
}
