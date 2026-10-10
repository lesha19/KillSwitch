import XCTest

final class UserErrorTests: XCTestCase {
    private let jargon = ["sudo", "unix", "utun", "mihomo", "ядр", "pf ", "dropweb", "sock"]

    private func assertPlain(_ error: UserError?, file: StaticString = #filePath, line: UInt = #line) {
        guard let error else { return XCTFail("no error", file: file, line: line) }
        for word in jargon {
            XCTAssertFalse((error.title + " " + error.message).lowercased().contains(word), "«\(word)» in \(error)", file: file, line: line)
        }
    }

    func testSudoWantsAPassword() {
        let error = UserError.from(raw: "sudo: a password is required", context: .helper)
        XCTAssertEqual(error?.title, "Службу нужно обновить")
        XCTAssertEqual(error?.message, "После обновления KillSwitch службе нужны новые права.")
        XCTAssertEqual(error?.action, .repair)
        XCTAssertEqual(error?.details, "sudo: a password is required")
        assertPlain(error)
    }

    func testCoreSocketMissing() {
        let raw = "dial unix /Library/KillSwitch/core/ctl/mihomo.sock: connect: no such file or directory"
        let error = UserError.from(raw: raw, context: .serverList)
        XCTAssertEqual(error?.title, "VPN не отвечает")
        XCTAssertEqual(error?.message, "VPN запущен, но не отвечает. Обычно помогает перезапуск.")
        XCTAssertEqual(error?.action, .restartVPN)
        XCTAssertEqual(error?.details, raw)
        assertPlain(error)
    }

    func testCoreNotInstalled() {
        let error = UserError.from(raw: "Ядро не установлено", context: .helper)
        XCTAssertEqual(error?.title, "VPN не установлен")
        XCTAssertEqual(error?.action, .repair)
        assertPlain(error)
    }

    func testSubscriptionNotFound() {
        let error = UserError.from(raw: "HTTP 404: Not Found", context: .subscription)
        XCTAssertEqual(error?.title, "Подписка не найдена")
        XCTAssertEqual(error?.message, "Проверь ссылку или продли подписку в сервисе. VPN работает со старыми серверами.")
        XCTAssertEqual(error?.action, .editSubscription)
        XCTAssertFalse(error!.message.contains("404"))
    }

    func testSubscriptionForbidden() {
        let error = UserError.from(raw: "HTTP 403", context: .subscription)
        XCTAssertEqual(error?.title, "Доступ к подписке запрещён")
        XCTAssertEqual(error?.message, "Сервис не пускает это устройство.")
        XCTAssertEqual(error?.action, .editSubscription)
    }

    func testOtherHTTPStatus() {
        let error = UserError.from(raw: "HTTP 502", context: .subscription)
        XCTAssertEqual(error?.title, "Сервис подписки не ответил")
        XCTAssertEqual(error?.action, .retry)
    }

    func testDeviceLimit() {
        let error = UserError.from(raw: "x-hwid-max-devices-reached", context: .subscription)
        XCTAssertEqual(error?.title, "Слишком много устройств")
        XCTAssertEqual(error?.message, "Удали старое устройство в боте или кабинете сервиса.")
        XCTAssertEqual(error?.action, .openAccount)
    }

    func testDeviceNotSupported() {
        let error = UserError.from(raw: "x-hwid-not-supported", context: .subscription)
        XCTAssertEqual(error?.title, "Сервис не принял это устройство")
        assertPlain(error)
    }

    func testOffline() {
        let error = UserError.from(raw: "offline (URLError -1009)", context: .subscription)
        XCTAssertEqual(error?.title, "Нет связи с сервисом подписки")
        XCTAssertEqual(error?.message, "Попробую ещё раз через 10 минут.")
        XCTAssertEqual(error?.action, .retry)
    }

    func testNewServersInARefresh() {
        let error = UserError.from(raw: "exit 3: В профиле новые адреса серверов (203.0.113.7)", context: .subscription)
        XCTAssertEqual(error?.title, "В подписке новые серверы")
        XCTAssertEqual(error?.message, "Разреши им работать при включённой защите.")
        XCTAssertEqual(error?.action, .approveServers)
    }

    func testNoServerAnswered() {
        let error = UserError.from(raw: "An error occurred in the delay test", context: .latency)
        XCTAssertEqual(error?.title, "Серверы не отвечают")
        XCTAssertEqual(error?.message, "Возможно, нет интернета. Проверь подключение к Wi-Fi.")
        XCTAssertEqual(error?.action, .recheck)
    }

    func testInstallFailure() {
        let error = UserError.from(raw: "visudo: syntax error\nmore", context: .install)
        XCTAssertEqual(error?.title, "Не получилось установить")
        XCTAssertEqual(error?.message, "visudo: syntax error")
        XCTAssertEqual(error?.action, .retry)
    }

    func testCancelledPasswordShowsNothing() {
        XCTAssertNil(UserError.from(raw: "User canceled. (-128)", context: .helper))
        XCTAssertNil(UserError.from(raw: "  ", context: .helper))
    }

    func testAnythingElse() {
        let error = UserError.from(raw: "pfctl: Syntax error in config file\nsecond line", context: .helper)
        XCTAssertEqual(error?.title, "Что-то пошло не так")
        XCTAssertEqual(error?.message, "pfctl: Syntax error in config file")
        XCTAssertEqual(error?.action, .copyDiagnostics)
        XCTAssertEqual(error?.details, "pfctl: Syntax error in config file\nsecond line")
    }

    func testActionTitles() {
        XCTAssertEqual(UserError.Action.repair.title, "Восстановить службу…")
        XCTAssertEqual(UserError.Action.restartVPN.title, "Перезапустить VPN")
        XCTAssertEqual(UserError.Action.openLoginItems.title, "Открыть Объекты входа")
        XCTAssertEqual(UserError.Action.editSubscription.title, "Изменить ссылку…")
        XCTAssertEqual(UserError.Action.approveServers.title, "Разрешить…")
        XCTAssertEqual(UserError.Action.recheck.title, "Проверить ещё раз")
    }

    func testStatusProblemsUseTheSameWords() {
        XCTAssertEqual(UserError.problem(.needsAccess).message, Status.broken(.needsAccess).line(Status.Detail()))
        XCTAssertEqual(UserError.problem(.serviceOff).title, "Служба KillSwitch выключена")
        XCTAssertEqual(UserError.problem(.serviceOff).action, .openLoginItems)
        XCTAssertEqual(UserError.problem(.vpnMissing).message, "В службе не хватает VPN — так бывает после старой версии.")
    }

    func testNetworkLeftOffByAStoppedService() {
        let error = UserError.networkLeftOff
        XCTAssertEqual(error.title, "Сеть выключена")
        XCTAssertEqual(error.action, .restoreNetwork)
        XCTAssertEqual(UserError.Action.restoreNetwork.title, "Включить сеть")
        XCTAssertTrue(error.message.contains("Объектах входа"), "says where the service is switched back on")
    }

    /// #17: damaged settings files block everything; «Сбросить настройки» runs `ks repair`, which
    /// opens the defaults again, so it needs the right like any other widening change.
    func testSettingsDamaged() {
        let error = UserError.settingsDamaged
        XCTAssertEqual(error.title, "Настройки защиты повреждены")
        XCTAssertEqual(error.action, .resetSettings)
        XCTAssertEqual(UserError.Action.resetSettings.title, "Сбросить настройки")
        XCTAssertTrue(error.message.contains("интернет заблокирован"), "says why nothing works")
        XCTAssertTrue(HelperCommand.repair.needsAuthorization)
        XCTAssertEqual(HelperCommand(ks: ["repair"]), .repair)
        XCTAssertNil(HelperCommand(ks: ["repair", "x"]))
    }

    func testDamagedApp() {
        XCTAssertEqual(UserError.damagedApp.title, "Программа повреждена")
        XCTAssertTrue(UserError.damagedApp.message.contains("Скачай программу заново"))
    }

    func testHWIDHeaderNames() {
        XCTAssertEqual(SubscriptionHeaders.hwidProblem(headers: ["x-hwid-max-devices-reached": "true", "x-hwid-active": "true"]),
                       "x-hwid-max-devices-reached")
        XCTAssertEqual(SubscriptionHeaders.hwidProblem(headers: ["x-hwid-not-supported": "true"]), "x-hwid-not-supported")
    }
}
