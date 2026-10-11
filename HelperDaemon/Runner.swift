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
            let copy: URL
            switch verifiedCopy() {
            case .success(let url): copy = url
            case .failure(let failure): return failure.reply
            }
            defer { PrivateDirectory.remove(copy.deletingLastPathComponent()) }
            let script = command.program == .install ? "install.sh" : "uninstall.sh"
            let path = copy.appendingPathComponent("Contents/Resources/Helper/\(script)").path
            return execute("/bin/bash", HelperCommand.scriptArguments(path, command.arguments))
        }
    }

    /// ADR 0012, no password: the code comes from the verified copy of our own bundle (the same
    /// signature this daemon runs under), and is put in place only if it is not older than the
    /// installed helper. install.sh --upgrade keeps the sudoers user and the protection state.
    private static func upgrade() -> HelperReply {
        let copy: URL
        switch verifiedCopy() {
        case .success(let url): copy = url
        case .failure(let failure): return failure.reply
        }
        defer { PrivateDirectory.remove(copy.deletingLastPathComponent()) }
        let helperDir = copy.appendingPathComponent("Contents/Resources/Helper")
        let installed = isRootOnly(directory, directory: true) && isRootOnly(ks, directory: false)
            ? FileManager.default.contents(atPath: ks) : nil
        let bundled = FileManager.default.contents(atPath: helperDir.appendingPathComponent("ks").path)
        let marker = installed != nil && isRootOnly(HelperVersion.markerPath, directory: false)
            ? FileManager.default.contents(atPath: HelperVersion.markerPath) : nil
        let completed = installed.map { HelperVersion.installCompleted(marker: marker, installed: $0) } ?? false
        switch HelperUpgrade.decide(installed: installed, bundled: bundled, completed: completed) {
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

    /// Why there is no verified copy. Only `.signature` is about the app; the rest is the daemon's
    /// own trouble, and the app falls back to the password (nothing ran).
    enum CopyFailure: Error {
        case ownPath, directory, copy(String), signature

        var reply: HelperReply {
            let text = switch self {
            case .signature: "Программа KillSwitch повреждена или подписана не нами: скачайте её заново"
            case .ownPath: "Служба KillSwitch не нашла свою программу"
            case .directory: "Служба KillSwitch не смогла создать временную папку"
            case .copy(let reason): "Служба KillSwitch не смогла скопировать программу: \(reason)"
            }
            return HelperReply(status: HelperReply.failedToRun, stdout: "", stderr: text)
        }
    }

    /// The bundle can be written by its user. Its copy in a root-only directory is checked and
    /// then used, so nothing can be swapped between the check and the run: every nested part and
    /// sealed resource (Helper/ included) intact and signed for our app by our team.
    private static func verifiedCopy() -> Result<URL, CopyFailure> {
        let result = makeVerifiedCopy()
        if case .failure(let failure) = result {
            Log.daemon.error("verified copy: \(String(describing: failure), privacy: .public), executable \(DaemonExecutable.current() ?? "?", privacy: .public)")
        }
        return result
    }

    private static func makeVerifiedCopy() -> Result<URL, CopyFailure> {
        // the kernel's path of this process, not Bundle.main (see DaemonExecutable.current)
        guard let bundle = DaemonExecutable.current().flatMap(DaemonExecutable.appBundle) else { return .failure(.ownPath) }
        guard let dir = PrivateDirectory.make() else { return .failure(.directory) }
        let copy = dir.appendingPathComponent(bundle.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: bundle, to: copy)   // a clone on APFS
        } catch {
            PrivateDirectory.remove(dir)
            return .failure(.copy(error.localizedDescription))
        }
        guard BundleSignature.isValid(copy, requirement: HelperIdentity.appRequirement) else {
            PrivateDirectory.remove(dir)
            return .failure(.signature)
        }
        return .success(copy)
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
