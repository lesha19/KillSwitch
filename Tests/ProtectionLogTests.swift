import XCTest
@testable import KillSwitch

final class ProtectionLogTests: XCTestCase {
    private func text(_ line: String) -> String? { ProtectionLog.entry(line)?.text }

    func testDateIsParsed() {
        let entry = ProtectionLog.entry("2026-10-10 14:03:22 core on")
        XCTAssertEqual(entry?.text, "VPN подключён")
        XCTAssertEqual(entry?.time, "10.10 14:03")
    }

    func testRepairsInPlainWords() {
        XCTAssertEqual(text("2026-10-10 14:03:22 pf was disabled: reloading"), "Защиту кто-то выключил — включена снова")
        XCTAssertEqual(text("2026-10-10 14:03:22 rules were changed or flushed: reloading"), "Защиту кто-то изменил — восстановлена")
        XCTAssertEqual(text("2026-10-10 14:03:22 anchor missing from main ruleset: reloading"), "Защиту кто-то изменил — восстановлена")
        XCTAssertEqual(text("2026-10-10 14:03:22 tunnels changed (utun5 198.18.0.1): reloading"), "VPN подключился или отключился — защита обновлена")
        XCTAssertEqual(text("2026-10-10 14:03:22 initial load: reloading"), "Защита включилась")
        XCTAssertEqual(text("2026-10-10 14:03:22 reload failed"), "Не получилось обновить защиту")
        XCTAssertEqual(text("2026-10-10 14:03:22 rules found loaded while off: flushed"), "Защита осталась включённой после выключения — снята")
        XCTAssertEqual(text("2026-10-10 14:03:22 main ruleset reloaded from /etc/pf.conf"),
                       "Другая программа заменила правила macOS — они загружены заново")
        XCTAssertEqual(text("2026-10-10 14:03:22 /etc/pf.conf has no com.apple anchor: main ruleset not reloaded, rules are not in effect"),
                       "Защита не действует: в /etc/pf.conf нет правил macOS")
    }

    /// ADR 0035: a line per gap, its length and why.
    func testGaps() {
        XCTAssertEqual(text("2026-10-12 17:02:43 internet closed for 8 s: update"), "Интернет был закрыт 8 с: обновление")
        XCTAssertEqual(text("2026-10-12 17:02:43 internet closed for 3 s: server switch"), "Интернет был закрыт 3 с: смена сервера")
        XCTAssertEqual(text("2026-10-12 17:02:43 internet closed for 125 s: reconnect"), "Интернет был закрыт 2 мин 5 с: переподключение")
        XCTAssertEqual(text("2026-10-12 17:02:43 internet closed for 120 s: VPN off"), "Интернет был закрыт 2 мин: до отключения VPN")
    }

    func testVPNEvents() {
        XCTAssertEqual(text("2026-10-10 14:03:22 core: 🚀 Выбор сервера -> 🇱🇹 Литва"), "Выбран сервер «🇱🇹 Литва»")
        XCTAssertEqual(text("2026-10-10 14:03:22 double VPN: off"), "Двойной VPN выключен")
        // ADR 0027: turned off by the helper, in words
        XCTAssertEqual(text("2026-10-10 14:03:22 double VPN off: its entry «🇩🇪Германия»: not a server of the subscription"),
                       "Двойной VPN выключен: сервера входа «🇩🇪 Германия» больше нет в подписке")
        XCTAssertEqual(text("2026-10-10 14:03:22 double VPN off: its entry «🇩🇪Германия»: it is the running server"),
                       "Двойной VPN выключен: «🇩🇪 Германия» сейчас и вход, и выход")
        XCTAssertEqual(text("2026-10-10 14:03:22 double VPN off: its entry «🇩🇪Германия»: it connects through another server itself"),
                       "Двойной VPN выключен: сервер входа «🇩🇪 Германия» больше не подходит")
        XCTAssertEqual(text("2026-10-10 14:03:22 double VPN off: no answer through «🇩🇪Германия»"),
                       "Двойной VPN выключен: через «🇩🇪 Германия» соединение не установилось")
        XCTAssertEqual(text("2026-10-10 14:03:22 double VPN off: «NL reality» was set for the other way of connecting"),
                       "Двойной VPN выключен: он был настроен для другого способа подключения")
        XCTAssertEqual(text("2026-10-10 14:03:22 double VPN back: «🇳🇱Нидерланды», no answer through «🇩🇪Германия»"),
                       "Через «🇩🇪 Германия» соединение не установилось — вход снова «🇳🇱 Нидерланды»")
        XCTAssertEqual(text("2026-10-10 14:03:22 apps outside the VPN: none"), "Программы без VPN: нет")
        XCTAssertEqual(text("2026-10-10 14:03:22 another VPN tunnel next to the core: utun6"), "Рядом работает другой VPN")
        XCTAssertEqual(text("2026-10-10 14:03:22 shutdown: network off (en0)"), "Mac выключается — сеть отключена")
        XCTAssertEqual(text("2026-10-10 14:03:22 watchdog switched off (Login Items): network left on"),
                       "Службу выключили в Объектах входа — сеть не отключалась")
        XCTAssertEqual(text("2026-10-10 14:03:22 network turned back on by hand"), "Сеть включена вручную")
        XCTAssertEqual(text("2026-10-11 14:03:22 detailed diagnostics: on"), "Подробная диагностика включена")
        XCTAssertEqual(text("2026-10-11 14:03:22 detailed diagnostics: off"), "Подробная диагностика выключена, записанные соединения удалены")
        XCTAssertEqual(text("2026-10-11 14:03:22 xray stats port 127.0.0.1:47891 is taken by another program: VPN without traffic counters"),
                       "Порт 47891 занят другой программой — VPN работает без счётчиков трафика")
        XCTAssertEqual(text("2026-10-11 14:03:22 xray stats port free again: traffic counters back"), "Счётчики трафика VPN снова работают")
        XCTAssertEqual(text("2026-10-11 14:03:22 core config rolled back: Xray did not come up with the new one"),
                       "VPN не запустился с новыми настройками — возвращены прежние")
        XCTAssertEqual(text("2026-10-11 14:03:22 core config: the new one refused by the core, the running one kept: x"),
                       "Новые настройки VPN не прошли проверку — оставлены прежние")
        XCTAssertEqual(text("2026-10-11 14:03:22 netbird: its daemon did not start again (launchctl bootstrap failed), next try in 30 s"),
                       "NetBird не запустился после перезапуска — следующая попытка позже")
        XCTAssertEqual(text("2026-10-11 14:03:22 netbird: its daemon started again"), "NetBird снова запущен")
        XCTAssertEqual(text("2026-10-11 14:03:22 netbird: reconnected after the restart (netbird up)"), "NetBird снова подключён")
        XCTAssertEqual(text("2026-10-11 14:03:22 netbird: reconnected by itself after the restart"), "NetBird снова подключён")
        XCTAssertEqual(text("2026-10-11 14:03:22 netbird: did not reconnect after the restart, run netbird up"),
                       "NetBird не подключился после перезапуска — подключите его заново")
    }

    /// «Размер пакетов VPN» (ADR 0032)
    func testTunnelMTU() {
        XCTAssertEqual(text("2026-10-12 14:03:22 tunnel MTU: 1380, VPN restarted"), "Размер пакетов VPN (MTU): 1380, VPN перезапущен")
        XCTAssertEqual(text("2026-10-12 14:03:22 tunnel MTU: auto, VPN restarted"), "Размер пакетов VPN (MTU): Авто, VPN перезапущен")
        // the VPN off or no subscription yet: nothing was restarted
        XCTAssertEqual(text("2026-10-12 14:03:22 tunnel MTU: 1380"), "Размер пакетов VPN (MTU): 1380")
        XCTAssertEqual(text("2026-10-12 14:03:22 tunnel MTU: 1280 refused, back to auto: the VPN did not start with it"),
                       "VPN не запустился с размером пакетов 1280 — вернули прежний: Авто")
        XCTAssertEqual(text("2026-10-12 14:03:22 MTU change cut short: undone"), "Прерванная смена размера пакетов VPN отменена")
    }

    func testRefusedServerSwitch() {
        XCTAssertEqual(text("2026-10-11 14:03:22 server switch to 🇱🇹Литва 2 refused: it sends other traffic past the VPN than approved"),
                       "Не переключились на «🇱🇹 Литва 2»: он пускает мимо VPN не то, что было подтверждено. Возьми подписку заново с паролем")
    }

    /// The automatic server switch is gone (ADR 0036): lines it left in events.log stay as they are.
    func testOldFailoverLinesAreNotRetold() {
        XCTAssertEqual(text("2026-10-11 14:03:22 failover (no answer): 🇱🇹Литва -> 🇱🇹Литва 2"), "failover (no answer): 🇱🇹Литва -> 🇱🇹Литва 2")
        XCTAssertEqual(text("2026-10-11 14:03:22 automatic server switch: on"), "automatic server switch: on")
    }

    /// Transport escalation (ADR 0030): the same server another way; never another server (ADR 0036).
    func testXrayEscalation() {
        XCTAssertEqual(text("2026-10-11 14:03:22 escalate (no answer): 🇱🇹Литва fingerprint chrome -> safari"),
                       "«🇱🇹 Литва» не отвечал — подключаемся к нему с другим отпечатком TLS: safari вместо chrome")
        XCTAssertEqual(text("2026-10-11 14:03:22 escalate (no answer): 🇱🇹Литва transport tcp -> xhttp"),
                       "«🇱🇹 Литва» не отвечал — подключаемся к нему по другому транспорту из подписки: xhttp вместо tcp")
        XCTAssertEqual(text("2026-10-11 14:03:22 escalate failed: 🇱🇹Литва fingerprint chrome -> safari, kept"),
                       "Не получилось сменить отпечаток TLS для «🇱🇹 Литва» — оставлен прежний")
        XCTAssertEqual(text("2026-10-11 14:03:22 escalate failed: 🇱🇹Литва transport tcp -> xhttp, kept"),
                       "Не получилось сменить транспорт для «🇱🇹 Литва» — оставлен прежний")
        XCTAssertEqual(text("2026-10-11 14:03:22 escalate reset (network changed)"),
                       "Сеть сменилась — серверы снова подключаются так, как задано в подписке")
        XCTAssertEqual(text("2026-10-11 14:03:22 escalate probing: 🇱🇹Литва"),
                       "«🇱🇹 Литва» не ответил дважды — проверяем другие способы подключения к нему")
        XCTAssertEqual(text("2026-10-11 14:03:22 escalate probing off: 🇱🇹Литва"),
                       "«🇱🇹 Литва» снова отвечает — другие способы подключения больше не проверяем")
        XCTAssertEqual(text("2026-10-11 14:03:22 escalate settled: 🇱🇹Литва"),
                       "«🇱🇹 Литва» снова работает так, как задано в подписке — вернулись к этому")
        XCTAssertEqual(text("2026-10-11 14:03:22 escalate probing failed: 🇱🇹Литва"),
                       "Не получилось проверить другие способы подключения к «🇱🇹 Литва»")
        XCTAssertEqual(text("2026-10-11 14:03:22 escalate settle failed: 🇱🇹Литва"),
                       "Не получилось вернуть «🇱🇹 Литва» к настройкам подписки")
        XCTAssertEqual(text("2026-10-11 14:03:22 connection escalation: on"), "Подбор отпечатка и транспорта включён")
        XCTAssertEqual(text("2026-10-11 14:03:22 connection escalation: off"), "Подбор отпечатка и транспорта выключен")
        // a name with the words in it: the kind is the last one
        XCTAssertEqual(text("2026-10-11 14:03:22 escalate (no answer): A transport B fingerprint chrome -> firefox"),
                       "«A transport B» не отвечал — подключаемся к нему с другим отпечатком TLS: firefox вместо chrome")
        XCTAssertNotNil(text("2026-10-11 14:03:22 escalate (no answer):  transport"))
        XCTAssertNotNil(text("2026-10-11 14:03:22 escalate failed: x"))
    }

    /// A server name that begins with the separator once made the line trap, and it stays in
    /// events.log, so Журнал защиты crashed every time it opened.
    func testServerNamesThatBeginWithTheSeparator() {
        XCTAssertEqual(text("2026-10-11 14:03:22 server switch to refused: A refused: it sends other traffic past the VPN than approved"),
                       "Не переключились на «refused: A»: он пускает мимо VPN не то, что было подтверждено. Возьми подписку заново с паролем")
        XCTAssertNotNil(text("2026-10-11 14:03:22 server switch to  refused: x"))
    }

    func testUnknownLineStaysAsIs() {
        XCTAssertEqual(text("2026-10-10 14:03:22 something new"), "something new")
        XCTAssertNil(ProtectionLog.entry(""))
    }
}
