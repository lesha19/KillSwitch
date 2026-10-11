import Foundation

/// The AppleScript behind the admin password prompt (`do shell script … with administrator
/// privileges`), run by osascript. Every argument becomes an AppleScript string literal passed
/// through `quoted form of`, so neither AppleScript nor the shell sees it as code: arguments come
/// from subscriptions and text fields (server names, addresses) and must not escape into a root
/// shell.
enum AdminScript {
    /// Several commands run as one, `&&`-joined: one password, and the first failure stops the rest.
    static func source(_ commands: [[String]]) -> String {
        let shell = commands
            .map { $0.map { "quoted form of \(literal($0))" }.joined(separator: " & \" \" & ") }
            .joined(separator: " & \" && \" & ")
        return "do shell script \(shell) with prompt \(literal(prompt)) with administrator privileges"
    }

    /// The text of the password dialog. osascript, not the app, asks macOS for the right, so
    /// without it the dialog would say «osascript wants to make changes».
    static let prompt = "KillSwitch хочет изменить настройки защиты. Введите пароль администратора, чтобы разрешить это."

    enum Outcome: Equatable, Sendable { case ok(String), cancelled, failed(String) }

    /// What an osascript run came to: stdout is the script's result (`do shell script` turns line
    /// ends into \r, osascript adds one \n); a failure is "<range>: execution error: <message>
    /// (<number>)" on stderr, and -128 is the person cancelling the prompt.
    static func outcome(status: Int32, stdout: String, stderr: String) -> Outcome {
        if status == 0 {
            var text = stdout
            if text.hasSuffix("\n") { text.removeLast() }
            return .ok(text.replacingOccurrences(of: "\r", with: "\n"))
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = trimmed.firstMatch(of: /(?s)execution error: (.*) \((-?[0-9]+)\)$/) {
            if match.2 == "-128" { return .cancelled }
            let message = String(match.1).replacingOccurrences(of: "\r", with: "\n")
            return .failed(message.isEmpty ? "Не получилось" : message)
        }
        return .failed(trimmed.isEmpty ? "Не получилось" : trimmed)
    }

    /// osascript's whole environment, so the root shell inherits nothing of the app's: any process
    /// of the user can set variables for the apps it starts (`launchctl setenv`), and BASH_ENV
    /// alone would run a file of its choice as root before the command.
    static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    /// A script of the app bundle as an admin command: `bash -p` ignores BASH_ENV, ENV,
    /// SHELLOPTS and exported functions as well.
    static func bundled(_ path: String, _ args: [String]) -> [String] { ["/bin/bash", "-p", path] + args }

    /// Runs `commands` as root behind one password prompt, bundled scripts from a verified copy.
    static func run(_ commands: [[String]]) async -> Outcome { await execute(source(commands.map { staged($0) })) }

    /// The scripts of the bundle that run as root.
    static let stagedScripts: Set<String> = ["install.sh", "uninstall.sh"]

    /// A bundled install.sh or uninstall.sh (`bundled`) as the password prompt runs it (#37): root
    /// copies the whole app into a fresh folder of its own, checks the copy's signature against
    /// `requirement` and runs the script of the copy, so nothing swapped in the bundle after the
    /// app's own check (BundleSignature) can run. The daemon does the same with its verified copy
    /// (ADR 0012, Runner) and the same requirement. Every other command is returned unchanged.
    static func staged(_ command: [String], requirement: String = HelperIdentity.appRequirement) -> [String] {
        let marker = "/Contents/Resources/Helper/"
        guard command.count >= 3, command[0] == "/bin/bash", command[1] == "-p",
              let range = command[2].range(of: marker, options: .backwards) else { return command }
        let app = String(command[2][..<range.lowerBound]), script = String(command[2][range.upperBound...])
        guard app.hasPrefix("/"), app.hasSuffix(".app"), stagedScripts.contains(script) else { return command }
        return ["/bin/bash", "-p", "-c", stagingScript, "killswitch-staged", app, requirement, script] + command.dropFirst(3)
    }

    /// `bash -p -c` text of `staged`: <app> <requirement> <script> <its arguments…>. Fixed text of
    /// the app, every value an argument. mktemp makes a 0700 folder in root's own temporary
    /// directory; `cp -H` copies the folder a link points at, never the link; the copy goes
    /// whatever happens. The refusal reads like the daemon's (Runner.CopyFailure.signature).
    static let stagingScript = """
        set -u
        app=$1 requirement=$2 script=$3; shift 3
        case $app in /*.app) ;; *) echo "KillSwitch: no app" >&2; exit 64 ;; esac
        case $script in install.sh|uninstall.sh) ;; *) echo "KillSwitch: no such script" >&2; exit 64 ;; esac
        dir=$(/usr/bin/mktemp -d) || exit 70
        trap '/bin/rm -rf "$dir"' EXIT
        /bin/cp -RH "$app" "$dir/KillSwitch.app" || { echo "KillSwitch: the app could not be copied" >&2; exit 70; }
        /usr/bin/codesign --verify --deep --strict --all-architectures -R "=$requirement" "$dir/KillSwitch.app" 2>/dev/null ||
          { echo "Программа KillSwitch повреждена или подписана не нами: скачайте её заново" >&2; exit 77; }
        /bin/bash -p "$dir/KillSwitch.app/Contents/Resources/Helper/$script" "$@"
        """

    /// Runs an AppleScript in its own /usr/bin/osascript process. NSAppleScript may only be used on
    /// the main thread (Apple's documentation), where the prompt and install.sh would freeze the
    /// app for minutes; a separate process has no such limit and the app keeps drawing. The text
    /// goes through stdin, so the arguments do not show in `ps`.
    static func execute(_ script: String) async -> Outcome {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-"]
            process.environment = environment
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            // read while running: install.sh may print more than a pipe buffer holds
            let outReader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            let errReader = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                Task {
                    let out = await outReader.value, err = await errReader.value
                    continuation.resume(returning: outcome(status: status, stdout: String(decoding: out, as: UTF8.self),
                                                           stderr: String(decoding: err, as: UTF8.self)))
                }
            }
            do {
                try process.run()
            } catch {
                try? output.fileHandleForWriting.close()   // ends the readers
                try? errors.fileHandleForWriting.close()
                continuation.resume(returning: .failed(error.localizedDescription))
                return
            }
            // a failed write ends osascript with an error, which the handler above reports
            try? input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
            try? input.fileHandleForWriting.close()
        }
    }

    /// An AppleScript string literal: backslash and double quote escaped.
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
