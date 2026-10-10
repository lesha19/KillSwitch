import Foundation

/// The AppleScript behind the admin password prompt (`do shell script … with administrator
/// privileges`). Every argument becomes an AppleScript string literal passed through
/// `quoted form of`, so neither AppleScript nor the shell sees it as code: arguments come from
/// subscriptions and text fields (server names, addresses) and must not escape into a root shell.
enum AdminScript {
    /// Several commands run as one, `&&`-joined: one password, and the first failure stops the rest.
    static func source(_ commands: [[String]]) -> String {
        let shell = commands
            .map { $0.map { "quoted form of \(literal($0))" }.joined(separator: " & \" \" & ") }
            .joined(separator: " & \" && \" & ")
        return "do shell script \(shell) with administrator privileges"
    }

    enum Outcome: Equatable, Sendable { case ok(String), cancelled, failed(String) }

    /// What a run of the script came to: error -128 is the person cancelling the prompt;
    /// `do shell script` turns line ends into \r.
    static func outcome(output: String?, errorNumber: Int?, errorMessage: String?) -> Outcome {
        if let errorNumber {
            return errorNumber == -128 ? .cancelled : .failed(errorMessage ?? "Не получилось")
        }
        guard let output else { return .failed("Не получилось") }
        return .ok(output.replacingOccurrences(of: "\r", with: "\n"))
    }

    /// Scripts run one at a time on this queue, never on the main thread: the prompt waits for the
    /// person and install.sh runs for a while. NSAppleScript is not thread-safe, so it is only ever
    /// created and run here.
    private static let queue = DispatchQueue(label: "killswitch.admin")

    static func run<T: Sendable>(source: String, _ execute: @escaping @Sendable (String) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: execute(source)) }
        }
    }

    /// An AppleScript string literal: backslash and double quote escaped.
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
