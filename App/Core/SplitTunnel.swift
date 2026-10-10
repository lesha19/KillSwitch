import Foundation

/// «Раздельный туннель»: programs that go around the VPN, by process name.
/// Helper contract: `ks set splitapps <comma list>` (requires coredirect=1); the current list is
/// `splitapps=` in /Library/KillSwitch/settings.
enum SplitApps {
    /// The main executable of an app bundle: what the core matches by process name.
    static func processName(infoPlist: [String: Any]) -> String? {
        guard let name = infoPlist["CFBundleExecutable"] as? String else { return nil }
        return isValid(name) ? name : nil
    }

    static func parse(setting: String?) -> [String] {
        adding((setting ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, to: [])
    }

    static func argument(_ names: [String]) -> String { names.joined(separator: ",") }

    /// Valid names appended, repeats dropped, order kept.
    static func adding(_ names: [String], to list: [String]) -> [String] {
        var result = list
        for name in names where isValid(name) && !result.contains(name) { result.append(name) }
        return result
    }

    /// No list separator, path or control characters; the length of a file name.
    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && !name.contains(",") && !name.contains("/")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

/// «Двойной VPN»: traffic enters through one server and leaves through the selected one.
/// Helper contract: `ks set multihop <entry proxy name>` or `ks set multihop off`; the current
/// entry is `multihop=` in /Library/KillSwitch/settings.
enum Multihop {
    static let off = "off"

    static func entry(setting: String?) -> String? {
        guard let value = setting?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value != off else { return nil }
        return value
    }

    /// «Вход: 🇩🇪 … → Выход: 🇱🇹 …»
    static func chain(entry: String, exit: String?) -> String {
        "Вход: \(label(entry)) → Выход: \(exit.map(label) ?? "?")"
    }

    /// Servers that may be the entry: not the exit, and names the helper accepts.
    static func candidates(_ names: [String], exit: String?) -> [String] {
        names.filter { $0 != exit && $0 != off && !$0.isEmpty && $0.utf8.count <= 255
            && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    }

    private static func label(_ name: String) -> String {
        let parts = ServerName(name)
        guard let flag = parts.flag else { return name }
        return name.hasPrefix(flag) ? name : "\(flag) \(name)"
    }
}
