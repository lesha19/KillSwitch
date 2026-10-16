# Как Mullvad и IVPN блокируют трафик (macOS): разбор первоисточников

Дата разбора: 2026-10-12. Ничего не запускалось (ни приложения, ни pfctl); всё прочитано из исходников и документации. Состояние pf на этом Маке не трогалось.

## 0. Метки, версии, источники

Метки у каждого утверждения:
- **[И]** из исходников (ссылка и строки);
- **[Д]** из документации (ссылка);
- **[В]** мой вывод из прочитанного, прямо в источнике не сказано;
- **[?]** неизвестно / не проверено.

Версии:
- Mullvad: ветка `main`, коммит `0ebc86ae9bd44a2c9bcf9f6a219641b2a5dab20d` (2026-10-12). Номера строк ниже именно для него.
- IVPN: ветка `master` = релиз v3.15.15, коммит `07e24591a999c6e9974ae19b795d22465fdcf89d` (2026-09-03). Ветка `development` (`1fd0630…`, 2026-10-06) отличается в firewall только сплит-туннелем; на выводы не влияет.

Короткие обозначения файлов Mullvad (база `https://github.com/mullvad/mullvadvpn-app/blob/0ebc86ae9bd44a2c9bcf9f6a219641b2a5dab20d/`):

| Код | Путь |
|---|---|
| M-sec | `docs/security.md` (спецификация поведения, написана самими авторами) |
| M-known | `docs/known-issues.md` |
| M-fw | `talpid-core/src/firewall/macos.rs` |
| M-fwmod | `talpid-core/src/firewall/mod.rs` |
| M-tsm | `talpid-core/src/tunnel_state_machine/mod.rs` |
| M-dis / M-con / M-cnd / M-dng / M-err | `talpid-core/src/tunnel_state_machine/{disconnected,connecting,connected,disconnecting,error}_state.rs` |
| M-lib | `mullvad-daemon/src/lib.rs` |
| M-tgt | `mullvad-daemon/src/target_state.rs` |
| M-shut | `mullvad-daemon/src/shutdown.rs` |
| M-main | `mullvad-daemon/src/main.rs` |
| M-mac | `mullvad-daemon/src/macos.rs` |
| M-pre / M-post | `dist-assets/pkg-scripts/preinstall`, `.../postinstall` |
| M-setup | `mullvad-setup/src/main.rs` |
| M-wg | `talpid-wireguard/src/connectivity/constants.rs` |
| M-chlog | `CHANGELOG.md` |
| M-gui | `desktop/packages/mullvad-vpn/src/...` (пути указаны там, где цитируются) |
| M-help | https://mullvad.net/en/help/using-mullvad-vpn-app |

Короткие обозначения файлов IVPN (база `https://github.com/ivpn/desktop-app/blob/07e24591a999c6e9974ae19b795d22465fdcf89d/`):

| Код | Путь |
|---|---|
| I-fw | `daemon/service/firewall/firewall.go` |
| I-fwd | `daemon/service/firewall/firewall_darwin.go` |
| I-sh | `daemon/References/macOS/etc/firewall.sh` (все pf-правила) |
| I-svc | `daemon/service/service.go` |
| I-conn | `daemon/service/service_connect.go` |
| I-proto | `daemon/protocol/protocol.go` |
| I-auto | `daemon/service/service_autoconnect.go` |
| I-launch | `daemon/launcher.go` |
| I-inst | `ui/References/macOS/HelperProjects/uninstaller/uninstaller.c` («IVPN Installer») |
| I-upd | `ui/References/macOS/HelperProjects/uninstaller/etc/install.sh` |
| I-plist | `ui/References/macOS/HelperProjects/helper/IVPN Helper-Launchd.plist` |
| I-ui | `ui/src/...` (пути указаны там, где цитируются) |
| I-kb | https://www.ivpn.net/knowledgebase/general/do-you-offer-a-kill-switch-or-vpn-firewall/ |

## 1. Таблицы: состояние × блокировка не-туннельного трафика

### 1.1 Mullvad (pf anchor `mullvad`)

Ключевая идея Mullvad: две разные вещи.
- **Kill switch** — всегда включён, отключить нельзя. Блокировка начинается в момент выхода из Disconnected (нажал Connect) и держится до явного Disconnect. [Д/И: M-sec L253-275, «The app has an always on "kill switch" that can't be disabled.»]
- **Lockdown mode** (бывший «Always require VPN», ещё раньше «block when disconnected») — только решает, блокировать ли в состоянии Disconnected. [И: M-sec L277-287; переименования: M-chlog L2335 (2020.5-beta1), L3094 (2018.6-beta1)]. Именно это у KillSwitch называется «защита».

| Состояние | Lockdown OFF (по умолчанию) | Lockdown ON | Источник |
|---|---|---|---|
| **Disconnected** | **Не блокирует.** Правил нет: `reset_policy` чистит правила anchor, снимает anchor и возвращает pf в прежнее «включён/выключен» | **Блокирует всё** (политика `Blocked`, как Error) | [И] M-sec L159-176; M-dis L72-107; M-fw L215-224, L938-972 |
| **Connecting** | **Блок**: наружу только до IP:порт первого хопа (и только от root) и до API-эндпоинта; в туннель пока почти ничего | так же | [И] M-sec L178-205; M-con L167-227; M-fw L363-411 |
| **Connected** | Весь трафик только через интерфейс туннеля + до сервера (root); DNS только к DNS туннеля | так же | [И] M-sec L207-221; M-fw L413-462 |
| **Disconnecting** | **Блок** (по коду: loopback + DHCP + NDP + опционально LAN, остальное `drop`) | так же | [И] M-dng L42-52; M-fw L481-491. Нюанс: документация говорит «не применяет свою политику, оставляет прежнюю» (M-sec L228-231), код применяет блокирующую. Для утечек разницы нет |
| **Error** | **Блок**, выйти можно только явным Disconnect | так же | [И] M-sec L233-251; M-err L21-102 |

Пояснения:
- Переход Connected → (новый сервер/реконнект) → Connecting идёт **через Disconnecting**, а не через Disconnected. Поэтому «Disconnected» (единственное небликирующее состояние при Lockdown OFF) наступает только по явной команде пользователя. [И] M-cnd L239-252, L348-349 (Connect → `Reconnect(0)`), M-dng L137-153 (`Nothing` → `DisconnectedState::enter(.., true)` — единственный путь к сбросу правил), M-sec L172-176: «The disconnected state is not active while the app changes server…».
- Смена политики на pf — одна транзакция: `pf.set_rules(anchor, AnchorChange{scrub,filter,nat,redirect})`. [И] M-fw L247-259; [Д] M-sec L23-26 («All changes to the rules are applied as atomic transactions»).
- Хвост каждой политики: `block return out quick` + `block drop quick all` (последние два правила). [И] M-fw L234-245.
- **Состояния соединений pf сбрасываются после каждого перехода**: «PF retains approved connections forever, even after a responsible anchor or rule has been removed». Исключения: loopback, mDNS :5353, LAN (если разрешён), API-эндпоинт, соединение с VPN-сервером (иначе ломается обмен ключами). [И] M-fw L88-90, L97-213.

### 1.2 IVPN (pf anchor `ivpn_firewall`, подякоря `tunnel`, `block_dns`, `route_*`)

Модель другая: **firewall — самостоятельный переключатель, не привязанный к состоянию VPN**. Состояния VPN (connecting/connected/reconnecting) сами по себе pf не меняют; меняют только `ClientConnected`/`ClientDisconnected` (добавить/снять подякорь `tunnel`) и список исключений. Включает и выключает firewall либо пользователь, либо настройки on-demand.

Настройки (UI → Settings → Firewall):
- «On-demand» и «Always-on firewall» (взаимоисключающие радио-кнопки); [И] I-ui `ui/src/components/settings/settings-firewall.vue` L5-43. Текст про always-on: «IVPN Firewall will always be active even when IVPN Client is not running» (там же).
- «Activate IVPN Firewall on connect to VPN» — по умолчанию **true**; «Deactivate IVPN Firewall on disconnect from VPN» — по умолчанию **true**; [И] I-ui `ui/src/store/module-settings.js` L151-153.
- «Allow LAN» и «Allow Multicast» — по умолчанию выключены (в `Preferences` нет значений по умолчанию, т.е. `false`; [И] `daemon/service/preferences/preferences.go` L82-85, L120-130); KB: «blocks access to local networks … by default» [Д через поиск: https://www.ivpn.net/knowledgebase/troubleshooting/i-cannot-access-devices-on-my-local-network-why/ — страницу целиком не открывал, [В] степень точности цитаты].
- «Allow access to IVPN servers when Firewall is enabled» — по умолчанию **true** (`IsFwAllowApiServers: true`, preferences.go L128).

| Состояние VPN | FW выключен (после Disconnect при on-demand, либо если «Activate on connect» снята) | FW включён on-demand (по умолчанию включается на Connect) | Always-on |
|---|---|---|---|
| Disconnected | **Не блокирует** | UI выключает FW при получении `DisconnectedResp`, если стоит «Deactivate on disconnect» (по умолчанию да) → не блокирует; если галка снята → **блок всего** | **Блок всего** кроме исключений |
| Connecting (первое подключение) | Не блокирует (FW не включён) | FW включается **до** подключения; наружу только до IP сервера (он добавляется в исключения) | то же |
| Connected | не блокирует | Только интерфейс туннеля + до сервера; всё остальное `route-to` в туннель с NAT (флаг `IS_DO_ROUTING=1`) | то же |
| Reconnecting (обрыв) | не блокирует | **Блок**: подякорь `tunnel` очищается, непостоянные исключения снимаются; IP сервера снова добавляется на состоянии RECONNECTING | то же |
| Paused | не блокирует | FW **выключается** на время паузы, если он не always-on | остаётся включённым |

Источники к таблице IVPN:
- Правила pf (хвост — `block return out quick all` + `block drop quick all`): [И] I-sh L113-164.
- Подякорь `tunnel` пропускает интерфейс туннеля и IP сервера: [И] I-sh L194-207; снимается в `-disconnected`: L279-287.
- Исключения (`exceptions`, `user_exceptions`) и DHCP `68→67`: [И] I-sh L131-141.
- Автовключение: [И] I-ui `ui/src/daemon-client/connectionParams.js` L123, L154 (`FirewallOn: firewallActivateOnConnect`); выключение: `ui/src/daemon-client/index.js` L486-494 (`firewallDeactivateOnDisconnect` → `EnableFirewall(false)`).
- Always-on запрещает выключение: [И] I-svc L821-824 («unable to disable Firewall in 'Persistent' state»).
- Пауза: [И] I-svc L647-676.

## 2. Реконнект / смена сервера / смена настроек при включённом соединении

### Mullvad
- **Блокирует всегда, независимо от Lockdown.** Путь `Connected → Disconnecting → Connecting`, все три политики блокирующие, смена политик атомарная. [И] M-cnd L348-349, M-dng L42-52, M-con L167-227. [Д] M-sec L253-275: «whenever the app changes server or temporarily loses tunnel connectivity it will ensure no network traffic leaks».
- Изменение `allow_lan` и DNS **во время Connected** на десктопе вообще не рвёт туннель: политика просто переприменяется на месте (на Android это реконнект). [И] M-cnd L263-285, L294-325.
- Обрыв туннеля обнаруживается пингами: ожидание трафика 5 с, затем ICMP каждые 3 с, до 15 с; при установке соединения таймаут 4 с, удваивается до 15 с. [И] M-wg L6-20.
- Пока идёт `Connecting`, трафика мимо туннеля нет. Если сервер не ответил — идёт повтор со следующим номером попытки (смена сервера выбирается по номеру попытки). [И] M-con L652-673.

### IVPN
- **Блокирует только если FW включён в этот момент.** Не зависит от «lockdown»-подобной настройки; зависит от того, включён ли переключатель «Firewall» (по умолчанию на сессии включается, см. таблицу выше).
- При смене сервера во время сессии клиент шлёт новый `Connect`; демон сначала останавливает текущее соединение, но **не рассылает клиентам `Disconnected`**, если новый запрос уже в очереди — поэтому UI не выключает FW. [И] I-proto L1274-1281 и L1321-1322 («Do not send "Disconnected" notification if we are going to establish new connection immediately»). Далее `connect()` снимает подякорь `tunnel` (`ClientDisconnected`, I-conn L652), остальные правила остаются → блок. [В] следует из I-sh L147-148 и L279-287.
- Автореконнект при обрыве: цикл `keepConnection` повторяет `connect()` вечно с паузой 5 с между подряд идущими попытками; если соединение уже было установлено, ошибки подавляются и идёт повтор. [И] I-conn L501-590 (L544 «throw error only on first try to connect»).
- **Дырка в режиме CLI**: `ivpn connect` выставляет `FirewallOnDuringConnection = true` (cli/commands/connection.go L468-480), а `connect()` на каждом выходе выключает FW (`if firewallDuringConnection && !fwInitState` → `SetKillSwitchState(false)`, I-conn L659-663), и включает заново только после определения исходящих IP, которое может ждать до минуты (I-conn L936, L943-974). То есть между попытками реконнекта FW в этом режиме снят. [В] по коду, не запускалось. Режим UI (`FirewallOn`) такой дырки не имеет (FW не выключается демоном).
- Не нашёл в IVPN ни одного сброса состояний pf (`pfctl -k`, `-F states`): grep по `firewall.sh` и `firewall_darwin.go` пусто. Открытые соединения могут продолжать жить по старым `keep state`. [И по отсутствию] I-sh, I-fwd.

## 3. Туннель не поднимается (сервер лежит, ошибка)

### Mullvad
- **Connecting** повторяется **без ограничения по времени**, правила остаются блокирующими; сервер каждый раз выбирается заново по номеру попытки; таймаут на каждую попытку растёт 4 → 8 → 15 с. [И] M-con L652-673; M-wg L13-18. Пользователь видит «Connecting…» и может нажать **Cancel** (это тот же `disconnectTunnel`, кнопка называется «Cancel» во всех состояниях кроме `connected`). [И] M-gui `renderer/components/views/main/components/connection-panel/components/disconnect-button/DisconnectButton.tsx` L22-30.
- В **Error** демон переходит только при неустранимой причине: нет подходящего сервера, аккаунт без времени, неверный аккаунт, устройство offline, не применилась политика pf, не поставился DNS, ошибка создания туннеля и т.п. [И] M-err L21-72 + список причин в GUI `shared/notifications/error.tsx` L100-200.
- Из Error выходит: (а) явный **Disconnect** (`TunnelCommand::Disconnect` → Disconnected, правила сброшены, если нет Lockdown) [И] M-err L218-223; (б) пользователь нажал Connect [И] M-err L205-217; (в) само: если причина `IsOffline` и сеть вернулась, или появилась недостающая версия IP [И] M-err L182-204. **Таймаута нет.** [Д] M-sec L246-247: «The user must then explicitly click disconnect in order to unlock the firewall».
- Выход из блока с помощью Lockdown OFF: Disconnect даёт полный доступ в интернет (единственный путь к небезопасному состоянию — действие пользователя). С Lockdown ON Disconnect оставляет блок, снять можно только выключением Lockdown. [Д] M-help (раздел Lockdown mode): «will also block the internet after you click on Disconnect or Quit».

### IVPN
- Первое подключение не удалось: ошибка возвращается, клиенту уходит `DisconnectedResp(Failure)`, UI выключает FW (при «Deactivate on disconnect»). [И] I-conn L544-547; ui `index.js` L486-494.
- Уже подключались, потом сервер упал: бесконечный цикл реконнекта (см. п.2), FW остаётся включён. Пока не нажмёшь Disconnect. Таймаутов нет. [И] I-conn L501-590. [Д] I-kb: «no traffic will leave the computer until IVPN Firewall is disabled manually».
- Always-on: выключить FW кнопкой нельзя, сначала надо переключить режим на On-demand. [И] I-svc L821-824.
- В UI есть предупреждение «Unhealthy connection. No traffic detected on the VPN tunnel.» при connected без трафика. [И] I-ui `ui/src/components/blocks/block-connect.vue` L10-20.

## 4. Обновление приложения / демона на macOS

### Mullvad: правила сохраняются, переподключение автоматическое

Механизм из трёх частей. [И] M-pre L25-37, L56-66; M-post L104-106, L122-137; M-lib L3342-3367; M-tgt.

1. **preinstall** (до замены файлов), по порядку:
   1. `mullvad-setup prepare-restart` — RPC `PrepareRestart` старому демону (команда в `mullvad-setup` описана так: «Move a running daemon into a blocking state and save its target state», M-setup L130-132).
      - Если цель была `Secured` (идёт сессия или auto-connect), демон посылает машине состояний `LockdownMode::yes().persist(true)` — т.е. переходит в блокирующее состояние **независимо от пользовательской настройки Lockdown**. [И] M-lib L3342-3363.
      - `target_state.lock()` — файл `target-start-state.json` в кэш-каталоге **не будет удалён** при остановке. [И] M-lib L3362 → M-tgt L116-119, L121-127.
   2. `launchctl unload -w /Library/LaunchDaemons/net.mullvad.daemon.plist` — остановка демона (SIGTERM).
   3. Только после этого `rm -rf` старого `.app` (комментарий: иначе сработает детектор удаления приложения, который запустит деинсталлятор). [И] M-pre L34-38; M-mac L54-175 (если `.app` исчез и процесса установщика нет — демон сам сбросит firewall и выйдет из аккаунта).
   4. Маркер `/var/run/mullvad-gui-was-running` (каталог доступен на запись только root) и `pkill` GUI.
2. **Остановка демона по SIGTERM на macOS всегда считается «не по воле пользователя»**: функция `is_shutdown_user_initiated()` на macOS **намеренно возвращает `false`**, чтобы не было утечек при выключении (комментарий: «launch daemon seemingly only receives a SIGTERM» — M-shut L30-44). Тогда при `target_state == Secured` **или** `auto_connect` перед выходом ставится `LockdownMode::yes()` («Block all traffic before shutting down to ensure that no traffic can leak on boot or shutdown»). [И] M-lib L3318-3335; M-main L208-215. Итог по [Д] M-sec L339-350: правила остаются при выходе, если Lockdown включён, **либо** остановка не явная пользователем **и** демон был в блокирующем состоянии или включён auto-connect; иначе правила снимаются.
3. **Правила остаются в ядре pf**: в `macos.rs` нет `impl Drop` и нет сброса при выходе; `reset_policy` вызывается только из `DisconnectedState` и `mullvad-setup reset-firewall`. [И] M-fw (grep `impl Drop` пусто), M-dis L96-103.
4. **postinstall**: пишет plist (`RunAtLoad=true`, `KeepAlive=true`, `UserName=root`), `launchctl load -w`; если GUI был запущен — открывает его от имени консольного пользователя. [И] M-post L64-68, L104-106, L122-137.
5. **Новый демон при старте**: читает `target-start-state.json`, видит `Secured`; `reset_firewall = (target_state != Secured)` → `false`: Disconnected-состояние **не** сбрасывает правила; сразу после этого `handle_initial_target_state` шлёт `Connect`, политика меняется на Connecting. [И] M-lib L960, L1136-1148; M-dis L96-103; M-tgt L12, L53-95. Правила pf остаются «чужими» до первого `apply_policy` нового демона.
6. Если цель была `Unsecured` (пользователь отключён, Lockdown OFF): ничего не блокируется ни до, ни во время обновления (правила и так сброшены), после обновления автоподключения нет. [В] следует из тех же строк.

Дополнительно:
- При auto-connect демон всегда стартует как `Secured` (`PersistentTargetState::new_secured`). [И] M-lib L880-885.
- Для Windows Mullvad делает правила на время обновления **непостоянными** (не переживают перезагрузку), «if the installation … fails and the user is left in blocked state with no app, they can reboot». [И] M-lib L3347-3355, M-chlog L535-537 (2025.8-beta1). На macOS `persist` = `true`, но правила pf в ядре и так живут только до перезагрузки [В: мои знания о pf, в источнике Mullvad не сказано].
- «Stop resetting the firewall after an upgrade to not leak after an upgrade.» — когда добавили: 2020.6-beta3. [И] M-chlog L2150. «Restore the last target state if the daemon crashes»: 2020.8-beta1. [И] M-chlog L2067.
- Документация предупреждает: если установщик не смог обновить приложение, интернет может остаться заблокированным. [Д] M-help (раздел Update the app): «The installer can fail to update the app and block the Internet…».
- Аварийный выход: `mullvad-setup reset-firewall` («Remove any firewall rules introduced by the daemon»), работает только когда демон не запущен. [И] M-setup L132-134, L236-250.

### IVPN: правила pf остаются; автопереподключения нет

- Обновление через приложение: «IVPN Installer --update» делает `ivpn disconnect` (обычный Disconnect), затем `install.sh` меняет `IVPN.app` целиком (`mv` в `.old`, `cp -R`) и запускает приложение. В `update()` **нет** выключения firewall (оно есть только в `uninstall()` и вызывается через `disableFirewall()`). [И] I-inst L413-450, L283-287, L332; I-upd L206-223.
- Но: UI при получении `DisconnectedResp` сам выключает on-demand FW (по умолчанию так). Если пользователь не на always-on, на время обновления защиты нет. [В] из ui/index.js L486-494 + то, что `update()` начинает с Disconnect.
- Обновление самого демона (privileged helper): при несовпадении версий приложение вызывает `IVPN Installer --install_helper`; при апгрейде `SMJobRemove(...)` старого helper и `SMJobBless` нового. [И] I-inst L186-260, `ui/src/daemon-client/darwin-installer.js` L26-60.
- Остановка демона **не трогает firewall**: `unInitialise()` отключает VPN и сплит-туннель, `Protocol.Stop()` только закрывает слушатель, `implStopped()` ничего не делает с pf; отключение FW есть лишь в `doCleanup()` (запуск с аргументом очистки). [И] I-svc L366-401; I-launch L212-240, L307-317; `daemon/launcher_darwin_libivpn.go` (`implStopped`). Значит при always-on правила остаются в ядре на время подмены демона.
- Новый демон на старте вызывает `SetPersistant(true)` (если always-on), а `-enable` при уже включённом FW ничего не меняет («Firewall is already enabled…»). [И] I-svc L256-271; I-fwd L82-93; I-sh L113-120.
- **Постоянного «целевого состояния» нет**: после остановки демона VPN не поднимется сам, только если включён «Auto-connect on launch» (`IsAutoconnectOnLaunch` + `IsAutoconnectOnLaunchDaemon`). [И] I-auto L205-213.
- [?] В KB сказано про «login item» агента, а в коде ветки master используется `SMJobBless`-helper. Что реально стоит в текущем релизном пакете — не проверено.

## 5. Падение / убийство демона

### Mullvad
- Правила pf **остаются** (нет Drop, нет вызова очистки при падении). [И] M-fw.
- `KeepAlive=true` — launchd перезапускает демон. [И] M-post L67-68.
- Файл `target-start-state.json` удаляется **только** при чистой остановке (`finalize()` без `lock()`; в `Drop` тоже), при падении остаётся, поэтому новый демон стартует в том же целевом состоянии и **не сбрасывает правила**, если оно было `Secured`. [И] M-tgt L14-19, L121-136, L159-171; M-lib L960. [И] M-chlog L2067 («Restore the last target state if the daemon crashes»).
- Если настройки не удалось разобрать — Lockdown включается принудительно (чтобы не стартовать без блока). [И] M-chlog L1523 (2022.1-beta2), L26-27 (`MULLVAD_LOCKDOWN_ON_INVALID_SETTINGS`).

### IVPN
- Правила pf **остаются** (нет вызова очистки на пути остановки, см. п.4). [И по отсутствию]
- Helper запускается с `KeepAlive=false` и `MachServices`: launchd сам не перезапустит, но любой XPC-обращение UI поднимает его заново (`--start_helper`: «OS will restart helper if it will crash»). [И] I-plist; I-inst L452-471.
- [Д] I-kb: «no traffic will leave the computer until IVPN Firewall is disabled manually» при падении клиента/туннеля/ОС. [Д] KB про агента: для always-on «it is important that the agent daemon is always running» (https://www.ivpn.net/knowledgebase/macos/why-is-ivpn-agent-daemon-always-running/).

## 6. Что видит пользователь в окне блокировки

### Mullvad (GUI)
| Состояние | Главная надпись | Баннер | Системное уведомление | Кнопка |
|---|---|---|---|---|
| Disconnected, Lockdown OFF | `DISCONNECTED` красным | нет | «Disconnected and unsecure» | Connect |
| Disconnected, Lockdown ON | `DISCONNECTED` белым | **`BLOCKING INTERNET`** + «<Lockdown mode> is enabled. Please click “Connect“ or disable “Lockdown mode“ to unblock internet.» | «Lockdown mode active, connection blocked» | Connect |
| Connecting | `CONNECTING...` | **`BLOCKING INTERNET`** | «Connecting to <hostname>» | **Cancel** |
| Reconnecting (Disconnecting+reconnect) | `DISCONNECTING...` | **`BLOCKING INTERNET`** | «Reconnecting» | кнопка Connect неактивна |
| Error | `BLOCKED CONNECTION` | **`BLOCKING INTERNET`** + причина («Your device is offline. The tunnel will automatically connect once your device is back online.» и т.п.) | зависит от причины | **Cancel** |
| Error, firewall не применился | `FAILED TO SECURE CONNECTION` красным | **`NETWORK TRAFFIC MIGHT BE LEAKING`** | высокая важность | Cancel |

[И] M-gui: `renderer/components/views/main/components/connection-panel/components/connection-status/ConnectionStatus.tsx` L33-56; `.../connection-action-button/ConnectionActionButton.tsx`; `shared/notifications/{block-when-disconnected.tsx,connecting.ts,reconnecting.ts,error.tsx,disconnected.ts}`; строки и контексты: `desktop/packages/mullvad-vpn/locales/messages.pot`.

В настройках Mullvad описывает разницу так (пользовательский текст): «Kill Switch will prevent any leaks … during automatic tunnel reconnects, software crashes and similar accidents» и «Manually disconnecting or quitting the app will block your connection» (при Lockdown). [И] `messages.pot` L2884-2889, L2896, L2940.

### IVPN (GUI)
- Крупно: «Your status is **connected / disconnected / paused**». Для реконнекта отдельного текста **не нашёл**; в трее мигающая иконка connecting. [И] I-ui `ui/src/components/blocks/block-connect.vue` L6-10, L229-233; `ui/src/tray.js` L235-245. [?] точная строка в окне при RECONNECTING — не нашёл.
- Отдельный переключатель **«Firewall»** с описанием «Ensure that all traffic is routed through VPN» (цвет переключателя другой при always-on). [И] `ui/src/components/blocks/block-connection-details.vue` L13-35.
- Баннера «блокирую интернет» нет: блокировку пользователь видит по переключателю Firewall.

## 7. Исключения при блокировке

### Mullvad (macOS)
Всегда (во всех блокирующих состояниях): [Д] M-sec L87-126, [И] M-fw L226-232, L702-710, L790-910.
- loopback `lo0`;
- DHCPv4 `68→255.255.255.255:67`, ответы `67→68`; DHCPv6 (`fe80::/10:546 → ff02::1:2, ff05::1:3 :547`);
- часть NDP (RS, RA, Redirect, NS, NA);
- LAN-сети `10/8, 172.16/12, 192.168/16, 169.254/16, fe80::/10, fc00::/7` + multicast — **только если** включено «Allow LAN» (по умолчанию выключено; [И] `mullvad-types/src/settings/mod.rs` L264), причём DNS-порт 53 блокируется **раньше** правил LAN; [И] M-fw L407-409, L473-477;
- вход/выход на сервер VPN (`peer_endpoints`) — **только для процессов от root** (`user = 0`) и только в Connecting/Connected; [И] M-fw L593-610;
- **API Mullvad** (`allowed_endpoint`) разрешён в Connecting, Error, Lockdown-Disconnected, но **не** в Disconnecting; на macOS/Linux — для любых процессов root; в Connected — только внутри туннеля; [Д] M-sec L133-139; [И] M-fw L612-632, L463-480;
- DNS: в блокирующих состояниях — `block return out` на порт 53 (кроме правил relay до этого); в Connected DNS только на серверы туннеля или заданные пользователем; [Д] M-sec L289-304; [И] M-fw L634-651.

### IVPN (macOS)
[И] I-sh L113-164, L289-339; I-svc L432-460; I-fw L238-253.
- `lo0`, DHCPv4 (`68→255.255.255.255:67` и обратно), без правил для NDP/ICMPv6 [В: не нашёл];
- таблица `exceptions`: IP VPN-сервера (временно, на время соединения), диапазоны LAN (если «Allow LAN», постоянно), IP API IVPN (по умолчанию да, постоянно);
- таблица `user_exceptions`: подсети из настроек «Exceptions»;
- DNS: если DNS не задан — блок :53; иначе разрешены только заданные серверы (внутренние идут через `route-to` туннеля).

## 8. Различия macOS и других ОС

### Mullvad
- Windows: WFP с постоянными фильтрами — переживают остановку службы и блокируют до старта BFE; на время обновления фильтры непостоянны. Linux: отдельный systemd-юнит `mullvad-early-boot-blocking.service` ставит блок до `network-pre.target`. macOS: **ничего подобного нет**. [Д] M-sec L353-366; [И] `dist-assets/linux/mullvad-early-boot-blocking.service`, M-lib L3347-3355.
- macOS-специфика: в блокирующих состояниях системный DNS переключается на локальный «фильтрующий» резолвер (127.x) с поддельными ответами для captive-portal проб Apple, «This fools the OS into thinking that it has connectivity». [И] `talpid-core/src/resolver.rs` L1-8; M-err L35-51.
- macOS: разовое NAT/route-to «обходное» правило для macOS 14.6–15.1 (сервисы Apple привязывают сокеты к физическому интерфейсу). [И] M-fw L26-45, L288-356.
- macOS: установка/обновление через `.pkg` и launchd (`net.mullvad.daemon`), скрипты preinstall/postinstall; детектор удаления `.app` (с проверкой «идёт ли установщик»). [И] M-pre, M-post, M-mac L54-175.
- Известные дыры самого Mullvad на macOS (документировано авторами): **утечки сразу после загрузки** («no way to ensure that our `mullvad-daemon` is started before any other service») и **иногда после системного апдейта macOS pf игнорирует правила** до перезагрузки. [Д] M-known L45-68, L179-197; [Д] M-help (Vulnerabilities → Early boot leaks on macOS).

### IVPN
- Windows: WFP с флагом `isPersistant` у провайдера и фильтров (переживают перезагрузку и работают до старта службы); Linux: iptables + цикл `ensurePersistant(60)`, потому что дистрибутивы затирают правила при загрузке; macOS: просто «убедиться, что FW включён при старте LaunchDaemon». [И] `daemon/service/firewall/firewall_windows.go` L50-76, L120-135, L295-330; `firewall_linux.go` L96-135; I-fwd L82-93.
- [Д] I-kb: «On Windows … reliable protection before the system is fully loaded», на macOS — «boot-time protection depends on the system configuration and service startup order».
- macOS: NAT + `route-to` для всего трафика через VPN (обход проблемы macOS 15 с iMessage/FaceTime). [И] I-sh L29-35, L209-276.

## 9. Что стоит скопировать KillSwitch (по приоритету)

1. **Разделить две вещи, как у Mullvad.** «Kill switch сессии»: как только пользователь нажал Connect, pf в режиме Connecting/Connected/Error, и так остаётся до явного Disconnect (или выхода с отключением), **независимо** от «защиты». «Защита» = Lockdown: блок ещё и в Disconnected. Это закрывает дыру в 1–10 с при любом рестарте ядра: рестарт, смена сервера и настроек — это Disconnecting → Connecting, а не Disconnected. [И] M-sec L253-287, M-cnd/M-dng.
2. **Смена политики одной атомарной загрузкой anchor** (Mullvad: `set_rules` одним вызовом), а не «снять правила, потом поставить». [И] M-fw L247-259.
3. **Сбрасывать состояния pf после каждого перехода**, оставляя соединение с сервером, loopback, mDNS 5353 и разрешённый LAN. Иначе старые `keep state` продолжают пропускать трафик. [И] M-fw L97-213. У IVPN этого нет.
4. **Файл «цель = защищён» на диске** (`target-start-state.json`): писать при Connect; удалять только при чистой остановке по воле пользователя; не удалять при `prepare-restart` и при падении. Новый демон: если файл говорит «защищён» → **не сбрасывать pf**, сразу переподключаться. [И] M-tgt L12-19, L116-136, M-lib L960, L1136-1148.
5. **Остановка по SIGTERM на macOS = «не по воле пользователя»**: при активной сессии перед выходом ставить блок и оставлять правила. Отличать «пользователь нажал Выйти/Отключить» (сброс) от «launchd/перезагрузка/обновление» (блок остаётся). [И] M-shut L30-44, M-lib L3318-3335.
6. **Обновление (Sparkle)**: перед заменой `.app` вызвать у демона команду `prepare-restart` (блок + замок на файл цели), затем остановить демон, заменить, запустить; порядок «сначала остановить демон, потом удалять старый `.app`» (иначе сработает детектор удаления). Если у KillSwitch есть похожий детектор удаления/деинсталляции, он не должен сбрасывать pf, пока идёт апдейт. [И] M-pre L25-38, M-mac L120-135.
7. **Error = блок без таймаута, выход только по явному Disconnect/Cancel**; офлайн — отдельная причина с автопереходом в Connecting, когда сеть вернулась. Connecting повторяется бесконечно с ростущим таймаутом попытки и сменой сервера. [И] M-err L182-223, M-wg L6-18, M-con L652-673. Кнопка «Cancel» видна во всех не-подключённых состояниях.
8. **Минимальный список исключений** (не выдумывать): loopback; DHCPv4/v6; необходимый NDP; сервер ядра (только для root/uid демона); API/лицензия (Mullvad пускает root-процессы; в Connected только внутри туннеля); LAN опционально; DNS блокируется везде кроме туннеля. [И] M-fw L226-232, L358-493, L593-651.
9. **UI**: баннер «BLOCKING INTERNET» в Connecting/Reconnecting/Error, отдельный красный баннер «NETWORK TRAFFIC MIGHT BE LEAKING», если pf не применился; в Lockdown-Disconnected — текст с кнопкой «Connect» или «выключить Lockdown». [И] M-gui (см. п.6).
10. **Аварийный выход**: команда сброса pf, работающая при остановленном демоне (`reset-firewall`), и честный текст в UI про зависший апдейт (Mullvad: правила в ядре pf до перезагрузки [В]).
11. **Не обещать защиту на загрузке macOS**: и Mullvad, и IVPN прямо пишут, что окно утечки при старте есть. [Д] M-known L45-68; I-kb.
12. (Опционально) локальный DNS-резолвер для блокирующих состояний, чтобы macOS не открывала окно captive portal. [И] resolver.rs L1-8.

Чего **не** копировать у IVPN: включение/выключение FW клиентом UI (защита зависит от того, жив ли UI и пришёл ли ему `DisconnectedResp`), отсутствие сброса состояний pf, режим «firewall только на время connect()» из CLI (дырка между попытками реконнекта), отсутствие сохранённой цели (после обновления/падения VPN не поднимается сам).

## 10. Не проверено / неизвестно

- [?] Точный текст pf-правил Mullvad в рантайме (строятся в коде; `pfctl -sr` не запускался, на этом Маке pf не трогал).
- [?] Остаются ли правила pf после перезагрузки macOS: в источниках Mullvad/IVPN не сказано; моё знание: pf-состояние рантаймное [В].
- [?] Как именно in-app updater Mullvad (`mullvad-update`) запускает `.pkg` на macOS (читал только сами pkg-скрипты и `docs`).
- [?] IVPN: что именно делает UI с firewall во время `--update` (читал установщик и обработчики, но не весь поток UI до запуска `update()`); вывод «на время обновления защиты нет при on-demand» — [В].
- [?] IVPN: текущая схема установки агента на macOS (SMJobBless в коде vs «login item» в KB).
- [?] IVPN: что видит пользователь точной строкой в окне при RECONNECTING.
- [?] Mullvad: список `AllowedClients` для API-эндпоинта на macOS (документ говорит «все процессы root»; в коде не проверял, откуда приходит `clients`).
- Реальное поведение обоих приложений не воспроизводилось: всё из чтения кода и документации.
