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

    /// An AppleScript string literal: backslash and double quote escaped.
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
