import Foundation

/// What a subscription link given by the person (Settings, a QR code, `killswitch://add`) does to
/// the one kept in the keychain (#23 review, ADR 0029). A new link replaces the old one only once
/// it answered: a link that fails must not cost the person the key that works.
enum SubscriptionChange: Equatable {
    /// No link yet: kept at once, so a first fetch that fails is tried again by the timer.
    case first
    /// Another link: fetched first; the old link, its status and its cache stay until it answers.
    case replace
    /// The same link again: an update.
    case same

    static func of(_ new: String, current: String?) -> SubscriptionChange {
        guard let current else { return .first }
        return current == new ? .same : .replace
    }

    var storesBeforeFetch: Bool { self == .first }
    /// The status (title, usage, provider texts) belongs to the old link until the new one answered.
    var resetsStatusBeforeFetch: Bool { self == .first }
    /// A failed fetch of a link not kept yet is no failed update of the kept one.
    var recordsFailure: Bool { self != .replace }

    /// What came of a link given by the person.
    enum Outcome: Equatable {
        /// Kept, and the core runs it (or nothing was to import).
        case applied
        /// Not applied: the fetch failed (lastError says why) or was abandoned. A replacing link is
        /// not kept and the old one stays; a first link stays kept and is tried again.
        case notKept
        /// Kept, but the import was cancelled or refused: the core still runs the old servers, and
        /// the next update takes the new link.
        case keptNotApplied

        var notice: String? {
            self == .keptNotApplied
                ? String(localized: "Новая подписка сохранена, но не применена: VPN пока работает со старыми серверами. Нажми «Обновить» в настройках VPN, чтобы применить (спросит пароль).")
                : nil
        }
    }

    /// Replacing while the main way is Xray with a service that has no Xray config. The refresh's
    /// advice («выбери запасной») would fetch the old link again, since the new one was not kept.
    func xrayFailure(raw: String) -> UserError? {
        guard self == .replace, raw == XrayProfile.Failure.notXray.errorDescription || raw.hasPrefix("HTTP 404") else { return nil }
        return UserError(title: String(localized: "Эта подписка не для основного способа подключения"),
                         message: String(localized: "Переключи способ подключения на запасной в настройках VPN, затем добавь ссылку снова. Текущая подписка осталась."))
    }
}
