import Foundation

/// «Раздельный туннель»: programs that go around the VPN, by the app bundle's path (every process
/// inside it) or, in lists from before 0.9.1, by process name.
/// Helper contract: `ks set splitapps <comma list>` (requires coredirect=1); the current list is
/// `splitapps=` in /Library/KillSwitch/settings.
enum SplitApps {
    /// The main executable of an app bundle: what the core matches by process name.
    static func processName(infoPlist: [String: Any]) -> String? {
        guard let name = infoPlist["CFBundleExecutable"] as? String else { return nil }
        return isValid(name) && !isPath(name) ? name : nil
    }

    /// What goes into the list for a picked app: its path, or its process name if the helper
    /// would not take the path.
    static func entry(bundle: URL, infoPlist: [String: Any]) -> String? {
        isValid(bundle.path) && isPath(bundle.path) ? bundle.path : processName(infoPlist: infoPlist)
    }

    static func isPath(_ entry: String) -> Bool { entry.hasPrefix("/") }

    static func parse(setting: String?) -> [String] {
        adding((setting ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, to: [])
    }

    static func argument(_ names: [String]) -> String { names.joined(separator: ",") }

    /// Limits of `ks set splitapps` (Helper/ks splitapps_parse).
    static let maxCount = 50
    static let maxBytes = 64
    static let maxPathBytes = 255

    /// Valid names appended, repeats dropped, order kept, at most `maxCount`.
    static func adding(_ names: [String], to list: [String]) -> [String] {
        var result = list
        for name in names where result.count < maxCount && isValid(name) && !result.contains(name) { result.append(name) }
        return result
    }

    /// Apps of the list that can be changed without the admin password: the bundle or the folder
    /// it sits in is writable for the user (`isWritable`, FileManager in the app). Every process
    /// started from inside such a bundle goes around the VPN, whoever put it there.
    static func userWritable(_ entries: [String], isWritable: (String) -> Bool) -> [String] {
        entries.filter { entry in
            guard isPath(entry) else { return false }
            return isWritable(entry) || isWritable((entry as NSString).deletingLastPathComponent)
        }
    }

    /// The small warning under «Программы без VPN»; nil when there is nothing to say.
    static func writableWarning(_ paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        let names = paths.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }.joined(separator: ", ")
        return String(localized: "\(names) можно изменить без пароля администратора, и всё, что запустится из \(paths.count == 1 ? String(localized: "него") : String(localized: "них")), пойдёт мимо VPN.")
    }

    /// What the helper accepts: no list separator or control characters, and either an absolute
    /// `.app` path without `.`/`..` parts or a process name without a slash.
    static func isValid(_ entry: String) -> Bool {
        guard !entry.isEmpty, !entry.contains(","),
              !entry.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        guard isPath(entry) else { return entry.utf8.count <= maxBytes && !entry.contains("/") }
        let parts = entry.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        return entry.utf8.count <= maxPathBytes && entry.hasSuffix(".app")
            && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
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
        String(localized: "Вход: \(label(entry)) → Выход: \(exit.map(label) ?? "?")")
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
