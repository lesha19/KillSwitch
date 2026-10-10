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

    /// Runs `commands` as root behind one password prompt.
    static func run(_ commands: [[String]]) async -> Outcome { await execute(source(commands)) }

    /// Runs an AppleScript in its own /usr/bin/osascript process. NSAppleScript may only be used on
    /// the main thread (Apple's documentation), where the prompt and install.sh would freeze the
    /// app for minutes; a separate process has no such limit and the app keeps drawing. The text
    /// goes through stdin, so the arguments do not show in `ps`.
    static func execute(_ script: String) async -> Outcome {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-"]
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
