import Foundation

/// Checks a command (the right, then the values) and runs it off the XPC queue.
enum Executor {
    /// Stands for the profile until the daemon has its own copy (see `perform`).
    static let profilePlaceholder = "/"
    /// What ks reads of a profile (`head -c 20000001`), larger ones are refused there.
    static let maxProfileBytes = 20_000_001

    private static let queue = DispatchQueue(label: "com.lesha19.KillSwitch.helper.run", attributes: .concurrent)

    static func perform(_ command: HelperCommand, authorization: Data? = nil, profile: FileHandle? = nil,
                        output: FileHandle? = nil, reply: @escaping @Sendable (Int32, String, String) -> Void) {
        Activity.shared.begin()
        queue.async {
            defer { Activity.shared.end() }
            let result = output.map { report(command, into: $0) } ?? run(command, authorization: authorization, profile: profile)
            Log.daemon.info("\(String(describing: command.program), privacy: .public) \(command.arguments.first ?? "", privacy: .public): \(result.status)")
            reply(result.status, result.stdout, result.stderr)
        }
    }

    private static func run(_ command: HelperCommand, authorization: Data?, profile: FileHandle?) -> HelperReply {
        if command.needsAuthorization {
            guard let authorization, Authorizer.check(authorization) else {
                return HelperReply(status: HelperReply.notAuthorized, stdout: "", stderr: "Нужно подтверждение администратора")
            }
        }
        var command = command
        var copy: URL?
        defer { if let copy { PrivateDirectory.remove(copy.deletingLastPathComponent()) } }
        if let profile {
            guard let path = copyProfile(profile) else {
                return HelperReply(status: HelperReply.failedToRun, stdout: "", stderr: "Не удалось прочитать профиль")
            }
            copy = path
            switch command {
            case .coreImport: command = .coreImport(profile: path.path)
            case .coreRefresh: command = .coreRefresh(profile: path.path)
            default: return HelperReply(status: HelperReply.refused, stdout: "", stderr: "Профиль не к этой команде")
            }
        }
        let needsCopy: Bool
        switch command {
        case .coreImport, .coreRefresh: needsCopy = true
        default: needsCopy = false
        }
        guard command.isValid, !needsCopy || copy != nil else {
            return HelperReply(status: HelperReply.refused, stdout: "", stderr: "Недопустимые данные")
        }
        return Runner.run(command)
    }

    /// «Собрать отчёт» (ADR 0021): ks writes the archive into a root-only folder of ours (it never
    /// gets a user's path), then only that archive is copied into the file the app opened.
    private static func report(_ command: HelperCommand, into output: FileHandle) -> HelperReply {
        defer { try? output.close() }
        guard case .diagReport(_, let uid) = command else {
            return HelperReply(status: HelperReply.refused, stdout: "", stderr: "Отчёт не к этой команде")
        }
        var info = stat()
        guard fstat(output.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, let dir = PrivateDirectory.make() else {
            return HelperReply(status: HelperReply.failedToRun, stdout: "", stderr: "Не удалось записать отчёт")
        }
        defer { PrivateDirectory.remove(dir) }
        let reply = Runner.run(.diagReport(directory: dir.path, uid: uid))
        guard reply.status == 0 else { return reply }
        guard let path = DiagReport.archive(printed: reply.stdout, in: dir.path),
              let input = FileHandle(forReadingAtPath: path) else {
            return HelperReply(status: HelperReply.failedToRun, stdout: "", stderr: "Отчёт не получился")
        }
        defer { try? input.close() }
        do {
            try output.truncate(atOffset: 0)
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try output.write(contentsOf: chunk) }
        } catch {
            return HelperReply(status: HelperReply.failedToRun, stdout: "", stderr: "Не удалось записать отчёт")
        }
        return HelperReply(status: 0, stdout: "", stderr: "")
    }

    /// The app's profile into a root-only directory of the daemon: ks then reads only our copy
    /// (it would otherwise open the path as root). Regular files only, at most what ks reads.
    private static func copyProfile(_ handle: FileHandle) -> URL? {
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let dir = PrivateDirectory.make() else { return nil }
        let url = dir.appendingPathComponent("profile.json")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var total = 0
        do {
            while total < maxProfileBytes, let chunk = try handle.read(upToCount: min(1 << 20, maxProfileBytes - total)),
                  !chunk.isEmpty {
                try out.write(contentsOf: chunk)
                total += chunk.count
            }
            try out.close()
        } catch {
            return nil
        }
        return url
    }

    /// The short name of a user id, thread-safe.
    static func userName(_ uid: uid_t) -> String? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        // pw_name points into the buffer: read it while the buffer is still alive
        return buffer.withUnsafeMutableBufferPointer { storage in
            guard getpwuid_r(uid, &entry, storage.baseAddress, storage.count, &result) == 0, result != nil else { return nil }
            return String(cString: entry.pw_name)
        }
    }
}

/// launchd starts the daemon again with the next message: it leaves when nothing ran for two
/// minutes, so an updated app's daemon replaces the old one soon.
final class Activity: @unchecked Sendable {
    static let shared = Activity()
    private let lock = NSLock()
    private var running = 0
    private var last = Date()
    private var timer: DispatchSourceTimer?

    func begin() { lock.withLock { running += 1; last = Date() } }
    func end() { lock.withLock { running -= 1; last = Date() } }

    /// Also as soon as nothing runs once the app was replaced (a Sparkle update renames a new
    /// bundle into place, ADR 0012): the app may keep it busy for longer than two minutes, and
    /// only the new daemon knows `upgrade`.
    func exitWhenIdle(after idle: TimeInterval = 120) {
        let path = DaemonExecutable.current()   // not Bundle.main: see there
        let started = path.flatMap(Self.fileIdentity)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [self] in
            let replaced = started != nil && path.flatMap(Self.fileIdentity) != started
            let quiet = lock.withLock { running == 0 && (replaced || Date().timeIntervalSince(last) > idle) }
            if quiet { exit(0) }
        }
        timer.resume()
        self.timer = timer
    }

    /// Device and inode of a file: a rename of another file over the path changes them.
    private static func fileIdentity(_ path: String) -> [UInt64]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return [UInt64(bitPattern: Int64(info.st_dev)), UInt64(info.st_ino)]
    }
}
