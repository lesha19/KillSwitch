import Foundation

/// An error as a person reads it (spec §6): what happened, what to do, one button. The raw text
/// of the helper or the network stays in `details`, for «Подробнее» and the diagnostics.
struct UserError: Equatable {
    enum Action: Equatable {
        case repair, restartVPN, openLoginItems, editSubscription, openAccount, retry, approveServers, recheck
        case chooseServer, copyDiagnostics, restoreNetwork

        var title: String {
            switch self {
            case .repair: "Восстановить службу…"
            case .restartVPN: "Перезапустить VPN"
            case .openLoginItems: "Открыть Объекты входа"
            case .editSubscription: "Изменить ссылку…"
            case .openAccount: "Открыть кабинет"
            case .retry: "Повторить"
            case .approveServers: "Разрешить…"
            case .recheck: "Проверить ещё раз"
            case .chooseServer: "Выбрать другой сервер…"
            case .copyDiagnostics: "Скопировать диагностику"
            case .restoreNetwork: "Включить сеть"
            }
        }
    }

    /// Where the raw text came from: the same words mean different things in different places.
    enum Context: Equatable {
        /// Any `ks` command (protection, connect, settings).
        case helper
        /// `ks core proxies`.
        case serverList
        /// `ks core delay` and server choice.
        case latency
        /// Fetching and applying the subscription. Raw texts are VPNClient's: `HTTP <code>[: hint]`,
        /// the hwid header name, `offline (…)`, `certificate (…)`, `empty`, `exit 3: …`.
        case subscription
        /// install.sh.
        case install
    }

    var title: String
    var message: String
    var action: Action?
    var details = ""

    /// Nil when there is nothing to show (the password prompt was cancelled, no text).
    static func from(raw: String, context: Context) -> UserError? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("(-128)"), !text.lowercased().contains("user canceled") else { return nil }
        var error = classify(text, context: context)
        error.details = text
        return error
    }

    /// The problems the summary status shows as «Нужна починка».
    static func problem(_ problem: Status.Problem) -> UserError {
        switch problem {
        case .needsAccess:
            UserError(title: "Службу нужно обновить", message: "После обновления KillSwitch службе нужны новые права.", action: .repair)
        case .vpnMissing:
            UserError(title: "VPN не установлен", message: "В службе не хватает VPN — так бывает после старой версии.", action: .repair)
        case .serviceOff:
            UserError(title: "Служба KillSwitch выключена",
                      message: "Её выключили в Системных настройках. Защита пока действует, но следить за ней некому.",
                      action: .openLoginItems)
        }
    }

    /// The service was stopped after it had turned the network off for the boot window
    /// (wifi-off-by-ks is there) and nothing will turn it back on: `ks netrestore`.
    static let networkLeftOff = UserError(
        title: "Сеть выключена",
        message: "Служба защиты остановлена и не включила Wi-Fi и другие сети обратно. Включи их здесь, а службу — в Объектах входа.",
        action: .restoreNetwork)

    /// The app bundle failed its signature check (BundleSignature): nothing from it runs as root.
    static let damagedApp = UserError(
        title: "Программа повреждена",
        message: "Подпись KillSwitch не сходится, поэтому служба не устанавливается. Скачай программу заново.",
        action: .copyDiagnostics)

    private static func classify(_ text: String, context: Context) -> UserError {
        let lower = text.lowercased()
        let firstLine = String(text.split(separator: "\n", maxSplits: 1).first ?? "")
        if lower.contains("a password is required") { return problem(.needsAccess) }
        if text.contains("Ядро не установлено") || lower.contains("core/mihomo: no such file") { return problem(.vpnMissing) }
        if lower.contains("mihomo.sock") || lower.contains("dial unix") || (context == .serverList && lower.contains("connect:")) {
            return UserError(title: "VPN не отвечает", message: "VPN запущен, но не отвечает. Обычно помогает перезапуск.", action: .restartVPN)
        }
        switch context {
        case .subscription:
            if let match = text.firstMatch(of: /^HTTP (\d{3})/) {
                switch Int(match.1) {
                case 404:
                    return UserError(title: "Подписка не найдена",
                                     message: "Проверь ссылку или продли подписку в сервисе. VPN работает со старыми серверами.",
                                     action: .editSubscription)
                case 403:
                    return UserError(title: "Доступ к подписке запрещён", message: "Сервис не пускает это устройство.", action: .editSubscription)
                default:
                    return UserError(title: "Сервис подписки не ответил",
                                     message: "VPN работает со старыми серверами. Попробуй обновить позже.", action: .retry)
                }
            }
            if text.hasPrefix("x-hwid-max-devices-reached") {
                return UserError(title: "Слишком много устройств", message: "Удали старое устройство в боте или кабинете сервиса.",
                                 action: .openAccount)
            }
            if text.hasPrefix("x-hwid-not-supported") {
                return UserError(title: "Сервис не принял это устройство",
                                 message: "Он не отдал серверы этому Mac. Напиши в поддержку сервиса.", action: .copyDiagnostics)
            }
            if text.hasPrefix("offline") {
                return UserError(title: "Нет связи с сервисом подписки", message: "Попробую ещё раз через 10 минут.", action: .retry)
            }
            if text.hasPrefix("certificate") {
                return UserError(title: "Сервис подписки не прошёл проверку",
                                 message: "Его сертификат недействителен, поэтому подписка не скачана.", action: .retry)
            }
            if text.hasPrefix("empty") {
                return UserError(title: "В подписке нет серверов",
                                 message: "Сервис прислал пустой ответ. Проверь подписку в боте или кабинете.", action: .editSubscription)
            }
            if text.hasPrefix("exit 3") {
                return UserError(title: "В подписке новые серверы", message: "Разреши им работать при включённой защите.",
                                 action: .approveServers)
            }
            return UserError(title: "Не получилось обновить подписку", message: firstLine, action: .retry)
        case .latency:
            return UserError(title: "Серверы не отвечают", message: "Возможно, нет интернета. Проверь подключение к Wi-Fi.",
                             action: .recheck)
        case .install:
            return UserError(title: "Не получилось установить", message: firstLine, action: .retry)
        case .serverList:
            return UserError(title: "Список серверов недоступен", message: firstLine, action: .retry)
        case .helper:
            return UserError(title: "Что-то пошло не так", message: firstLine, action: .copyDiagnostics)
        }
    }
}
