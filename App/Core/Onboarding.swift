import Foundation

/// «Начало работы» (spec §4): the first-run wizard. The subscription comes before the install,
/// while the internet still works; the install, the import and connecting are one admin command,
/// so one password and no minute without internet.
enum Onboarding {
    enum Step: Equatable { case welcome, subscription, install, filter, done }

    /// Computed once when the wizard opens, so the steps do not shift under it as setup goes on.
    /// Reopened after a close in the middle, it starts from what is still missing.
    static func steps(installed: Bool, hasServers: Bool, filterOn: Bool) -> [Step] {
        var steps: [Step] = []
        if !installed { steps.append(.welcome) }
        if !installed || !hasServers { steps += [.subscription, .install] }
        if !filterOn { steps.append(.filter) }
        steps.append(.done)
        return steps
    }

    /// The admin command of step «Установка»: install.sh (skipped when the service is there),
    /// `ks core import`, `ks core on`.
    static func commands(installScript: String?, user: String, servers: [String], helper: String, profile: String) -> [[String]] {
        var commands: [[String]] = []
        if let installScript { commands.append(["/bin/bash", installScript, user] + servers) }
        commands.append([helper, "core", "import", profile])
        commands.append([helper, "core", "on"])
        return commands
    }

    /// What the checked link brought.
    struct Found: Equatable {
        var title: String?
        var servers: Int
        var expire: Date?
        /// Share links or a WireGuard file instead of a subscription.
        var ownServers = false

        var ready: Bool { servers > 0 }

        /// «Подписка «StorkVPN · Премиум»: 6 серверов, до 2 ноября».
        func line(calendar: Calendar = .current) -> String {
            var text = ownServers ? String(localized: "Свои серверы") : String(localized: "Подписка") + (title.map { " «\($0)»" } ?? "")
            text += ": " + Russian.plural(servers, String(localized: "сервер"), String(localized: "сервера"), String(localized: "серверов"))
            if let expire {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "ru_RU")
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.setLocalizedDateFormatFromTemplate("dMMMM")
                text += String(localized: ", до ") + formatter.string(from: expire)
            }
            return text
        }
    }
}
