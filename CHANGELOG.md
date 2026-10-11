# Changelog

All notable changes to KillSwitch are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) (0.x: no stability promise).

## [Unreleased]

### Added
- Settings › Дополнительно «Перенос настроек» (#15, ADR 0024): «Сохранить в файл…» writes the app
  and protection settings to a JSON file, «Загрузить из файла…» reads one back, «Сбросить…» returns
  them to the defaults. Both show every change first; protection settings go through the usual
  commands and password. The file never contains the subscription link, own servers or keys.

## [0.18.1] - 2026-10-11

### Added
- Server list: «Недавние» (last 5 chosen, #13), «Порядок» by subscription / ping / name (#25), a
  filter by country, protocol or group, and the subscription's server description under the name
  (#40). Ping is drawn as three signal bars; with Xray the ping-all button is off.
- Settings › Общие «Запускать без окна»: start in the menu bar only (#40).
- The provider's announcement (`announce`, `announce-url` headers, plain or `base64:`) on the main
  screen until ✕, again when the text changes; support link and e-mail (`support-url`,
  `support-email`) in «О программе» (#22). Plain text only, links only http(s)/tg/mailto.
- `hide-url` header: «Показать» of the subscription link is off and the link is never revealed (#26).
- Settings › Общие «Сети Wi‑Fi» (#39): per network «Подключаться автоматически» (connects there even
  with the general switch off) and «Предпочитаемый сервер» (picked when the Mac joins it). Nothing
  turns protection off for a network. Location access is asked for on the first «Добавить текущую
  сеть», after an explanation; the names stay on this Mac. Auto-connect now also applies a server
  picked while disconnected.
- QR codes (#24, ADR 0022): «Сканировать QR…» in Settings › VPN adds a subscription or servers
  from a QR code in a clipboard picture (⌃⇧⌘4), an image file or a dropped one, through the same
  checks as a typed link; no Screen Recording permission. «QR-код…» shows the subscription link as
  a QR code for a phone after a warning; not offered when the subscription sends `hide-url`.

### Fixed
- NetBird stayed disconnected after KillSwitch restarted its daemon (0.18.0, NetBird 0.78): when
  it was connected before, KillSwitch now runs `netbird up` once the daemon is back (bounded in
  time, in the background) and logs whether it reconnected; a NetBird the user turned off with
  `netbird down` is left down.

## [0.18.0] - 2026-10-11

### Added
- A local diagnostics journal (ADR 0021) in `/Library/KillSwitch/diag` (root-only, kept 7 days and
  about 50 MB): once a minute the state as a JSON line (core, protection, a probe through the VPN,
  traffic, network, DNS), and the events the watchdog notices (sleep and wake, tunnels, the core's
  start, stop and restart, network and DNS changes). Nothing leaves the Mac.
- «Подробная диагностика (все соединения)» in Settings › Дополнительно, off by default: with Xray
  every connection is recorded with its site (`ks set diag 0|1`); switching it off deletes them.
- «Собрать отчёт» in «Журнал защиты»: one archive on the Desktop with the journal, logs, state,
  versions, network and crash reports of the last 7 days (`ks diag report <folder>`, no password).
  Server addresses and names become `server-N`, every other public IP address `ip-N` (loopback,
  LAN, Tailscale and our TUN stay readable); links, UUIDs and keys are masked; the subscription's
  profile and the core's config are never included. Crash reports are only the system's and the
  asking user's, read with that user's rights (never a linked file); through the helper daemon
  only the user at the Mac (or the one who installed the helper) can collect the report.
- Xray: the stats API (counters only, on 127.0.0.1:47891), so `ks core traffic` works with Xray.
  If another program holds that port, Xray starts without the counters (logged in «Журнал защиты»).
- Upgrades with Xray: the rebuilt config replaces the running one only after `xray run -test`, and
  if Xray does not come up with it within about 5 s the previous config is restored.
- «О программе → Лицензии»: the licences of Xray-core, mihomo, the geodata, Sparkle and Yams with
  links to their source code; the project's own `LICENSE` (#36).
- «Бета-версии» in «О программе»: updates from Sparkle's beta channel (#16);
  `KS_CHANNEL=beta scripts/release.sh --publish` publishes one.
- Each release carries the source of the bundled mihomo (GPL-3.0) and Xray-core tags, sha256-pinned,
  and the app no longer ships `Helper/tests` and other dev-only scripts (#36).

### Fixed
- NetBird works with protection on: its daemon binds WireGuard, STUN, relay and management
  connections to Wi‑Fi/Ethernet, past any VPN, so pf dropped them and peers stayed «Connecting».
  The watchdog now starts NetBird's launchd job with the new group `_ksnetbird` (only while the
  plist runs code signed by NetBird GmbH, team TA739QLA7A, and the Tailscale setting is on) and pf
  lets that group out; the content filter trusts NetBird's signature like Tailscale's. One switch
  for both: Settings › Защита › «Tailscale, NetBird». A NetBird update that rewrites its plist is
  tagged again within seconds; turning the switch off or uninstalling takes the group off. Each
  change restarts NetBird's daemon once, in the background (the kill-switch loop never waits for
  it); a restart that fails is tried again (30 s, doubling) and logged.
  Known limit: pf lets out everything NetBird's daemon sends, its DNS forwarder and netstack proxy
  included, not only WireGuard, STUN, relay and management traffic.
- «Установить и перезапустить» did nothing while a sheet was open (e.g. «Начало работы»); a build
  installed but not relaunched is now relaunched or offered with «Перезапустить» (#35).
- A subscription link without its scheme (`host/token`) kept its token in «Скопировать диагностику»
  and in «Собрать отчёт»; the host is now masked with its port and path (#26).

## [0.17.0] - 2026-10-11

### Added
- Xray-core as the main way of connecting (ADR 0020): Xray v26.9.30 (pinned, `Helper/fetch-xray.sh`)
  with its own TUN, built from the panel's Xray config (`<subscription>/json`); mihomo stays as the
  fallback in Settings › VPN «Способ подключения». New installs get Xray; existing ones keep mihomo
  until switched (one password). `geoip.dat` is shipped pinned for Xray's GEOIP rules. With Xray
  «Трафик» shows only the rules; ping, speed and «Двойной VPN» are mihomo-only for now.

### Fixed
- DNS: our `127.0.0.1` is never recorded as a network service's original DNS, and stopping the
  core (and uninstalling) always removes it from the Wi‑Fi/Ethernet DNS (ADR 0017). Before, a lost
  or stale `dns-state` could leave the Mac resolving through a core that was gone.
- Another VPN (Happ) is no longer cut when protection is switched on or installed while our VPN is
  off: protection stands by and blocks again within a second of that VPN going (ADR 0018).
- mihomo: no sniffing of plain HTTP or of connections to bare addresses, the program is looked up
  only for «Программы без VPN», and nothing is sent DIRECT back into our own tunnel (ADR 0019).
- A compiler warning in the updater (a main-actor property read inside a KVO callback).

## [0.16.0] - 2026-10-10

### Added
- Fail closed on damaged settings (#17, ADR 0015): if a root state file the protection rules are
  built from (`settings`, `allow`, `servers`, `servers-manual`, `tsrelays`, `core/egress`) is not a
  root-owned regular file, is writable by others, or holds a line `ks` never writes, everything
  but loopback is blocked, the reason goes to `/Library/KillSwitch/invalid`, and the app shows
  «Настройки защиты повреждены» with «Сбросить настройки» (`ks repair`). A missing `settings`
  still means the defaults.
- Backup subscription link and fetch through the VPN (#11, ADR 0016): the subscription is tried
  directly, then through the running VPN (a local-only HTTP inbound that always goes to a server),
  then the backup link the same two ways. The source used is shown under the subscription. A
  failed subscription refresh or update check is retried when the VPN connects.

### Changed
- Geodata (#27): `install.sh` installs `geosite.dat` / `geoip.metadb` only when their SHA-256
  matches the pin, keeps the old file otherwise and reports each file in Settings; downloads in
  `fetch-geodata.sh` time out after 3 minutes.

## [0.15.2] - 2026-10-10

### Fixed
- The privileged daemon read `mkdtemp`'s path after its buffer was released: in the release
  build the path came back empty, «Восстановить службу…» and the update after an app update
  failed («Cannot make directory /KillSwitch.app»), and the failure path tried to remove `/` as
  root (the read-only system volume stopped it). The path is read inside the buffer's scope, and
  the daemon removes only its own `killswitch.*` directories in its temporary directory
  (`PrivateDirectory`). The same lifetime bug in `getpwuid_r` is fixed too.
- `install.sh` stopped half-way when the settings held only the old `coredirect=1`
  (`grep -v` leaves nothing and exits 1 under `set -e`): the new `ks` was in place, the core,
  sudoers and the watchdog were not, and the app never retried. It now writes
  `/Library/KillSwitch/installed` (version and SHA-256 of `ks`) as its last step; the app and the
  daemon run the install again when it is missing or names another `ks` (ADR 0012 addendum).
- `install.sh` no longer stops silently: an ERR trap prints `install.sh:<line>: exit <status>`,
  the passwordless-access check fails the install explicitly, and a failed script run through the
  daemon shows its stderr in the banner instead of its progress lines.
- The update check's KVO handler hopped onto the main actor by assertion
  (`MainActor.assumeIsolated`), which traps when called off the main thread; it now hops with a
  task.

## [0.15.1] - 2026-10-10

### Fixed
- 0.15 crashed at launch when the privileged daemon refused or dropped the connection: the XPC
  error, reply and invalidation blocks of `HelperClient` were taken for main-actor code and
  trapped on XPC's queue (`daemonBuild`). They are `@Sendable` now; a test keeps every XPC block
  in that file `@Sendable`. The VPN and protection were not affected.

## [0.15] - 2026-10-10

Routing comes only from the subscription, and the app shows where traffic goes (ADR 0013, #8).

### Added
- «Трафик» in the window's sidebar (`killswitch://traffic`), three tabs:
  - «Правила»: every rule of the subscription in its order, grouped by where it sends traffic
    («Напрямую», a server or group, «Блок»), searchable; rule sets expand to their source host,
    size, update time and (inline) entries; what was not taken from the subscription and why;
    «Добавлено KillSwitch» with the reason for each item; the sniffer and DNS taken from the
    subscription with their values.
  - «Соединения»: the core's open connections with program and icon, host, rule, route
    (flag + server), bytes and duration; filter direct / VPN / blocked, search, pause, a bar of
    direct vs VPN traffic. Polled once a second only while the tab is on screen.
  - «Проверить адрес»: which rule a site or address meets and where it goes, walked locally
    over the rules and the shipped geodata; what cannot be told here is listed as approximate.
- `ks core connections` (passwordless, also over the daemon): the open connections without
  source addresses, ports or uid, plus rule-provider sizes and update times.
- `core/routing.json` (world-readable, no secrets): what the generator took, left out and added.
- The subscription's `sniffer` and `dns` policy (`fake-ip-filter`, `nameserver-policy`,
  `direct-nameserver`, `respect-rules`) are taken, validated. Without a sniffer, a routing-only
  default (TLS/HTTP/QUIC, destination not overridden) is enabled and listed as KillSwitch's.
- Every protocol the bundled mihomo 1.19.32 has for one server can be used (#9): MASQUE,
  TrustTunnel, Sudoku, ShadowQUIC and OpenVPN join VLESS (Reality, Vision, xHTTP with a separate
  download server, ML-KEM encryption), VMess, Trojan, Shadowsocks/2022 (obfs, v2ray-plugin,
  gost-plugin, ShadowTLS, Restls, JLS, kcptun), Hysteria, Hysteria2, TUIC, WireGuard with
  AmneziaWG and a preshared key, AnyTLS, Mieru, SSH, Snell, SOCKS5 and HTTP.
- Links: vmess:// (v2rayN and URI form), anytls://, socks5:// and http(s):// proxies; xHTTP links
  bring Xray's `extra` (padding, XMUX, download server); ss:// links with v2ray-plugin or
  shadow-tls; wireguard:// links with AmneziaWG fields (#21).

### Changed
- pf lets the core reach addresses outside the tunnel only when the subscription has DIRECT
  rules or a DNS policy with outside servers, or programs without VPN are chosen
  (`core/egress`); before, only with «Российские сайты напрямую», so a subscription's own
  DIRECT rules were silently cut without it.
- A rule mihomo cannot take (unknown type, missing target or rule set, `SUB-RULE`, `IP-ASN`,
  GEOSITE/GEOIP without geodata) is left out with a reason instead of failing the import.
- «Программы без VPN» works on its own.
- The core always records the program of a connection (`find-process-mode: always`).

### Removed
- «Российские сайты напрямую» (`coredirect`): the setting, its switches on the main screen and
  in Settings, and the app's own RU/private-network rules. The setting is dropped on upgrade;
  geodata stays for the subscription's GEOSITE/GEOIP rules and ad blocking.

### Fixed
- 0.14.2: «Службу нужно обновить» could not be fixed — the passwordless upgrade and «Восстановить
  службу…» both ended with «Программа KillSwitch повреждена или подписана не нами» on an intact
  app. The daemon looked for its app through `Bundle.main`, which is not reliable for a daemon
  launchd starts as the relative `Contents/MacOS/KillSwitchHelper`; it now takes its path from
  the kernel (`proc_pidpath`) with the same checks, and its «exit once the app was replaced»
  timer uses the same path. Only a failed signature check says the app is damaged; any other
  failure of the daemon's verified copy is logged with its step and the app falls back to the
  password prompt (only on a click) instead of a dead end. Updating from 0.14.2: the app sees the
  older daemon (build 18), sends its reads through sudo so it goes idle and leaves (≤ 2.5 min),
  and launchd starts the fixed daemon for the passwordless upgrade (ADR 0012).

### Security
- The helper keeps only the keys mihomo reads for each protocol and refuses a certificate or
  private key given as a file path, a `dialer-proxy` outside the profile, hysteria2 realms and
  unknown shadowsocks plugins (ADR 0014). TUIC's `ip` and the xHTTP download server are pinned
  and added to the servers pf lets the core reach; nothing else is opened. Tailscale, ZeroTier
  and EasyTier outbounds stay refused: they need addresses outside the server list.


## [0.14.2] - 2026-10-10

### Fixed
- No more «KillSwitch.app запрашивает доступ к данным других приложений» at launch: the app no
  longer reads dropweb's profiles (`~/Library/Application Support/org.dropweb.vpn`) or Happ's group
  container to suggest server addresses. «Адреса серверов для других VPN-программ» are typed by
  hand; other VPNs are still recognised by `scutil --nc list` and the routes.
- Nothing asks for the administrator's password without a click: every prompt (osascript's and
  the daemon's authorization dialog) passes `AdminGate`, which refuses requests from launch,
  refresh and timers and logs each request with its reason
  (`log stream --predicate 'subsystem == "com.lesha19.KillSwitch" && category == "admin"'`). The
  automatic resume after «Пауза до переподключения» used a click's path with the password
  fallback; it now only tries the passwordless `ks on`.
- The privileged daemon is registered again: a daemon that was never registered can read
  `.notFound` from SMAppService, which 0.14.1 took for a build without the daemon, so it never
  called `register()` and never showed the Login Items notice. The notice also shows while the
  daemon is still not registered. Registration logs its status and error (category `helper`).

- The passwordless helper upgrade (ADR 0012) also starts as soon as the daemon is switched on in
  Login Items, not only at the next launch.

### Notes
- `ks` changes only its version line. With the daemon allowed it is upgraded without a password;
  until then the main screen shows «Службу нужно обновить» and waits for the click.
- The osascript dialog keeps osascript's icon (ADR 0002 addendum); with the daemon allowed in
  Login Items, macOS's own dialog naming KillSwitch replaces it.

## [0.14.1] - 2026-10-10

### Fixed
- The macOS filter extension is now updated with the app: at launch the app reads which version
  macOS runs and, if the bundled one is newer, asks macOS to replace it (before, an extension from
  0.6 kept running after every update). Nothing is asked when the version is the same; if macOS
  wants an approval, a notice opens System Settings while the old version keeps filtering. pf stays
  the primary layer during the swap (ADR 0012 addendum).
- The privileged daemon (ADR 0010) is registered at launch when the helper is installed but the
  daemon is not, so Touch ID, the 5-minute authorization and the passwordless update work on Macs
  set up before it. While it waits for the switch in Login Items, a dismissible notice «Разреши
  KillSwitch в Объектах входа…» opens them, at most once a day.

## [0.14] - 2026-10-10

Updating no longer interrupts the VPN and needs no manual steps (ADR 0012).

### Added
- «Обновлять автоматически» in «О программе», on by default (`SUAutomaticallyUpdate`): Sparkle
  downloads the update in the background and it is installed, with a relaunch of the app, as soon
  as KillSwitch is not the active app. The tunnel, pf and DNS live in the root daemons and are not
  touched by quitting or replacing the app.
- Daemon command `upgrade`: after an app update the privileged daemon puts the bundled helper in
  place without a password (`install.sh --upgrade` from its verified copy of the signed bundle),
  never an older helper over a newer one. Then a notice «Обновление установлено — VPN не
  прерывался» instead of «Восстановить службу…».
- `install.sh --upgrade`: in-place upgrade for the user the sudoers entry already names; leaves
  protection on, off or paused as it was; exit 2 when not installed, exit 4 on a downgrade.
- `ks _regen` (internal, root only): a new config generator's output is hot-reloaded through the
  core's API, without restarting the core.

### Changed
- `install.sh` (also «Восстановить службу…») no longer drops the connection: files are replaced
  by rename, the watchdog takes a new `ks` by SIGHUP (`ks watch` re-execs itself; before, a
  `bootout` made its shutdown guard switch Wi-Fi and Ethernet off), pf is never flushed, and the
  core restarts only if its binary, geodata or plist changed (before: on every run).
- The daemon exits as soon as its app was replaced and nothing runs, so a new daemon takes over
  within 30 s; the app routes its reads around a daemon of an older build until then.

## [0.13] - 2026-10-10

The helper changed (new passwordless `ks core traffic`, `ks set adblock`), so «Восстановить
службу…» is asked once: it also rewrites the sudoers entry.

### Added
- Privileged helper daemon `KillSwitchHelper` (ADR 0010): a root daemon inside the app, registered
  with SMAppService and reached over XPC only by our signed app (code-signing requirement both
  ways). Changes that widen the rules ask for the authorization right
  `com.lesha19.KillSwitch.widen` (an admin's password or Touch ID, valid 300 s) instead of a
  password per change. It runs `/Library/KillSwitch/ks` and the bundle's `install.sh` /
  `uninstall.sh` from a verified copy, with typed, checked commands, `bash -p` and only the system
  `PATH` in its environment. Until it is allowed in System Settings › Login Items the password
  prompt works as before. Hardened runtime is on for every target.
- Shortcuts, Spotlight and Siri (App Intents): «Подключить VPN», «Отключить VPN», «Сменить
  страну» (a server of the «Серверы» list, searchable in Russian) and «Статус VPN» (also returns
  the text), with Russian phrases. They do what the menu does and say back what needs the window.
- Right click (or ⌃-click) on the menu bar icon: a compact menu with Подключить/Отключить, Самый
  быстрый, Открыть KillSwitch, Проверка утечек and Выход. A left click still opens the popover.
  The icon is now an AppKit status item with an NSPopover hosting the same main screen
  (ADR 0011).
- Another program's VPN is recognised beyond the 198.18 address: any utun, ipsec or ppp tunnel
  (WireGuard, IKEv2, L2TP…) that takes the default route or splits it, IPv4 or IPv6, both by the
  app (`netstat -rn`) and by the watchdog (`core/foreign-vpn`). Ours and Tailscale's (100.64/10,
  fd7a:115c:a1e0::/48, exit node included) are not counted. What pf lets through is unchanged.
- «Стоит знать» in «Проверка утечек» and «О программе»: a non-blocking tip when iCloud Private
  Relay is on (the system's own status; unknown means no tip) or Tailscale, ZeroTier or NetBird
  runs, explaining how each works with the protection.
- Split tunnel integrity: Settings › VPN warns under «Программы без VPN» when an app in the list
  (or the folder it sits in) can be changed without the admin password, since everything run from
  that path goes around the VPN.
- «Скорость VPN в строке меню» in Settings › Общие (off by default): ↓/↑ next to the icon, read
  once a second only while it is on and our VPN is connected, through the new passwordless
  `ks core traffic` (only the totals of mihomo's /connections leave the helper; in sudoers and
  the daemon's passwordless commands, exact arguments). With an older helper the app says so and
  never prompts.
- «Блокировать рекламу и трекеры» in Settings › Дополнительно (off by default): the core refuses
  `GEOSITE,category-ads-all` of the shipped, sha256-pinned geosite.dat (nothing is downloaded).
  REJECT sends nothing anywhere, so the DIRECT signature and pf are unchanged. Helper setting
  `ks set adblock 0|1` (needs the updated helper); like every `set` it asks for the admin
  password or the daemon's right.
- Release transparency: every release carries `SHA256SUMS` of the .dmg, appcast.xml,
  geosite.dat and geoip.metadb (`scripts/release.sh` writes it and `--publish` uploads it); README
  «Проверка загрузки» tells how to check it and the Developer ID signature.

### Changed
- The string catalog is complete: the texts built in code (status, errors, notifications, the
  protection log, leak test findings, menus, settings rows…) go through `String(localized:)` and
  are in `Localizable.xcstrings` (224 → 596 keys); `StatusLabel` takes a literal as a catalog key.
  A test keeps App/Core free of texts outside the catalog.
- Favourites and «Подключение к серверу» overrides are kept by a server's identity (type, address,
  port and a hash of its uuid/password; the secret itself is not stored), not by its name, so a
  rename in the subscription keeps them. Name-keyed data from earlier versions is moved over once
  the server is in the profile.
- `Helper/fetch-geodata.sh` takes geosite.dat and geoip.metadb from our own releases first
  (`scripts/release.sh --publish` now uploads the pinned files and their sha256 to
  lesha19/KillSwitch-releases) and from the pinned meta-rules-dat commit only when a copy is
  missing or of another pin, so a force-push upstream no longer breaks the build. Each is checked
  against its pinned sha256; `release.sh` refuses either file if it is not the pinned one.
- `scripts/release.sh` signs the daemon with the hardened runtime and checks the app's and the
  daemon's designated requirements.

### Fixed
- `xcodebuild test` from a fresh DerivedData no longer fails with «Unable to find module
  dependency: 'KillSwitch'»: the test target depends on the app (built first, not hosted).

## [0.12.1] - 2026-10-10

Security fixes from the internal audit of everything that runs as root
(docs/security/audit-2026-10.md). The helper changed, so «Восстановить службу…» is asked once:
it also rewrites the sudoers entry.

### Безопасность
- The helper no longer runs with the environment of the program that calls it through sudo. It
  sets its own `PATH` and `HOME` and drops the rest. The user's `~/.curlrc` and similar files can no
  longer change what root downloads.
- Subscription profiles are checked key by key. A rule provider whose name has a line break in
  it could get past the checks before. Unknown provider fields and types are now refused.
- `geoip.metadb` (Russian addresses outside the VPN) is no longer copied by root from dropweb's
  folder. It ships inside the app, pinned by sha256, like `geosite.dat`.
- The administrator prompt no longer passes the app's environment to the root shell. Bundled
  scripts run with `bash -p`.
- The copy of the profile and the core's config (server passwords) are root-only from the moment
  they are written.
- The installer accepts only a real user account for the passwordless commands. The helper refuses
  extra or malformed arguments to those commands.
- «Отключить Happ и подключить KillSwitch» passes only a real VPN service id to `scutil`.

## [0.12] - 2026-10-10

Another program's VPN (Happ and the like) is named and can be replaced with one click (ADR 0009).
The helper changed only its version line, but the app compares the whole file, so «Восстановить
службу…» is asked once.

### Fixed
- With Happ connected and protection on, sites Happ sends directly (often Russian ones: lava.ru,
  ggsel, digiseller…) stopped opening without a word of why. The main screen and the popover now
  say «Работает другой VPN (Happ)» and «KillSwitch не подключён. Сайты, которые тот VPN пускает
  напрямую (часто российские), защита блокирует.» — an orange warning, never «Защищено».
- The «почему ничего не отвечает» check no longer blames the provider while another VPN took the
  routes.
- The leak test says when the tunnel it checked was another program's («Проверен другой VPN»)
  instead of a plain «Утечек нет».
- The widget's VPN mark shows our VPN only.

### Added
- «Отключить Happ и подключить KillSwitch»: stops the other VPN without a password
  (`scutil --nc stop`) and connects ours. If it cannot be stopped from here, the button opens
  that app instead.
- Auto-connect still never stops another VPN by itself; it now says so in a notification.

## [0.11] - 2026-10-10

One app, one window. The helper changed only its version line, but the app compares the whole
file, so «Восстановить службу…» is asked once.

### Changed
- One window with a sidebar instead of four windows (ADR 0008): «Главная», «Серверы»,
  «Проверка утечек», «Журнал защиты», «Настройки» (Общие, VPN, Защита, Дополнительно) and
  «О программе». The separate Settings window, leak-test window and wizard window are gone.
- «Начало работы» is a sheet of the window and can be closed with ✕ or Esc.
- The 0.10 «Помощь» tab is split: the log and «Скопировать диагностику» are in «Журнал защиты»;
  version, updates and tips in «О программе».
- Everything that leads further — the popover's «⋯» items, notification buttons, error buttons,
  ⌘, ⌘0 ⌘L ⇧⌘L — opens the same window at the right section and brings it forward if it is
  already open. The window remembers its section, size and place.
- The menu bar popover stays as quick access: status, connect, server choice.

### Added
- «Главная» in the sidebar carries the summary as a colour dot (and its title for VoiceOver).
- `killswitch://` links open a section (`killswitch://settings/vpn`, `killswitch://leaks`, …);
  a click on the widget outside its button opens «Главная». Links never change protection or
  the VPN.

## [0.10] - 2026-10-10

For people in Russia: blocked servers, «white lists», captive Wi‑Fi. Needs «Восстановить службу…»
once: the helper, its pf rules and its sudoers entry changed (`ks probe`).

### Added
- Auto-failover within the chosen country: each country with two or more servers becomes a
  hidden mihomo `fallback` group; when the picked server stops answering, the core moves to
  another server of the same country, the status line says which, and a notification follows
  (at most every 10 minutes). If the whole country is down, a banner offers «Самый быстрый» or
  another server; another country is never picked by itself (ADR 0005).
- «Why nothing works»: while no server answers, the app asks the helper (passwordless
  `ks probe`, at most once a minute) whether there is a network, whether a Russian address open
  in the mobile «white lists» answers and whether foreign ones do, and shows «Нет подключения
  к сети», «Интернета нет», «Оператор пускает только на российские сайты» or «Серверы VPN
  недоступны» with what to do. pf lets only the core's group reach the Russian probe addresses,
  TCP 443 (ADR 0006).
- Settings › Дополнительно › «Подключение к серверу»: TLS fingerprint and multiplexing
  (sing-mux) per server, default «Как в подписке»; the helper accepts only known values on the
  protocols mihomo supports, applied without a password (ADR 0007). mihomo has no TLS fragment
  option, so there is none.

### Changed
- Auto-connect is on by default (new installs and anyone who never touched the switch);
  trusted Wi‑Fi networks and the location permission they need are explained in Settings
  (ADR 0004).
- «Домашняя сеть» is now «Доступ к домашней сети», with what it covers; default unchanged (on).

### Security
- IPv6: with «Доступ к домашней сети» off or DNS protection on, DNS to link-local and multicast
  IPv6 addresses (a router's RDNSS resolver) is blocked like IPv4 DNS; tests cover that nothing
  but link-local, multicast and the tailnet passes over IPv6 (ADR 0003).
- The admin password prompt runs in `osascript` instead of NSAppleScript off the main thread
  (not thread-safe) (ADR 0002).

## [0.9.1] - 2026-10-10

Fixes from the 0.9 review. Needs «Восстановить службу…» once: the helper, its sudoers entry and
the core's plist changed.

### Security
- A passwordless subscription refresh can no longer widen what goes outside the VPN through a
  rule provider: the url or payload of a provider used by a DIRECT rule, and any provider's own
  download proxy (e.g. `proxy: DIRECT`), are part of what needs the admin's approval. The first
  refresh after the update may ask once for profiles with such providers.
- The widget's «Выключить» and pause open the app with a question instead of the password
  prompt: its notifications can be posted by any program. «Включить» still works directly.
- Before install.sh / uninstall.sh run as root, the app checks its own signature (nested code and
  sealed resources, our team); a damaged bundle shows «Программа повреждена» and runs nothing.
- Split tunnel matches an app by its bundle's path (all its processes, helpers included), not by a
  process name any program could take. Lists from older versions keep working.
- The core logs at warning level (info wrote every visited domain); core.log is root-only, the core
  directory is not listable, and the log is capped at 2 MB with one older copy.
- A switch-off that raced the watchdog could leave the rules loaded while «off»; the watchdog now
  flushes them.

### Fixed
- A service switched off in Login Items no longer leaves Wi-Fi and Ethernet off with nothing to
  turn them back on; if that happened before, the app shows «Сеть выключена» with
  «Включить сеть» (new passwordless `ks netrestore`).
- The UI no longer freezes while the password prompt is up or install.sh runs.
- A subscription the helper did not take (password needed, new servers, an error) no longer counts
  as updated: «Обновлено» moves only when the profile is in the VPN; otherwise again in an hour.
- The app notices a service from another version (`ks version`, file comparison) and offers
  «Восстановить службу…».
- An empty address in the filter's list could crash the system extension.

### Changed
- Much less polling: the watchdog runs once a second (tunnels every pass, pf every 2 s, the DNS
  lock only when DNS has to be rewritten) and publishes `/Library/KillSwitch/daemon-state`; the
  app watches that file instead of running sudo and launchctl every 3 s, and polls only while its
  popover, window or Settings is open. The content filter caches tunnel state (1 s) and signature
  checks (10 s per process).
- The watchdog reloads `/etc/pf.conf` (when another program dropped Apple's anchor point) only if
  that file has the anchor point, and logs it.
- ⇧⌘L opens the leak test; Reduce Motion turns off the slide to the server list.
- Plain words in «Журнал защиты» for the new events.

## [0.9] - 2026-10-10

Interface rework after the UX audit (`docs/ux/audit.md`, `docs/ux/spec.md`).

### Added
- First-run wizard «Начало работы»: subscription first (checked while the internet still works),
  then install, server import and connecting as one admin command — one password, and protection
  never comes up without a VPN; an optional «Защита macOS» step; auto-connect, launch at login and
  notifications on the last step. The leak test learns the provider's address on the way.
- Menu bar popover with the main screen instead of the menu; one summary status drives the icon
  (eleven states, ten distinct icons) and the VoiceOver label, changes are announced.
- Server choice: a flat list of countries with «Самый быстрый», search (also by country in
  Russian), favourites, sort by ping, ping as bars and words; a server chosen while disconnected is
  used by the next «Подключить». Subscription groups stay behind a switch in Settings → VPN.
- Notifications per event with buttons (connect, renew, approve servers…), at most once in
  10 minutes, each switchable in Settings → Общие: «VPN снова работает» after a drop, the
  subscription at 3 days and 1 day left and past 90 % of traffic.
- «Журнал защиты» in plain words; the leak test also probes for a direct exit while protection is on.
- `docs/adr/0001-fewer-password-prompts.md`: batching now, privileged daemon with Touch ID planned.
- `App/Localizable.xcstrings` (source language ru) for proofreading.

### Changed
- Errors in plain words with one action each; raw text under «Подробнее» and in diagnostics.
- Settings in five tabs (Общие, VPN, Защита, Дополнительно, Помощь); lists and switches that let
  traffic around the VPN are edited in a sheet and applied with one password.
- Protection is an always-on mode: the main button is «Подключить / Отключить»; pause and off live
  in «⋯» and Settings → Защита. «Обновить защиту» is now «Восстановить службу…».
- One dictionary for words on screen: no core, tunnel, pf or filter.

### Fixed
- Arguments of admin commands are AppleScript string literals: a server or address name can no
  longer escape into the root shell.
- The entry-server picker of double VPN showed only the flag; names with their own emoji got an
  extra 🌐.

## [0.8] - 2026-10-10

### Added
- Russian sites outside the VPN by default on a new install (`coredirect=1`, «Российские сайты —
  напрямую (мимо VPN)»): split-tunnel rules for private networks, `GEOSITE,category-ru` and `GEOIP,RU`;
  geodata ships with the app (`Helper/fetch-geodata.sh`, sha256-pinned) and is never auto-updated.
- Double VPN (multihop): pick an entry server, the selected server is the exit; `ks set multihop`.
- Split tunnel by app: chosen programs go around the VPN; `ks set splitapps`.
- Leak test window: IPv4/IPv6 address and DNS resolvers with a verdict.
- WireGuard: AmneziaWG options and several `[Peer]` sections.
- Auto-connect on start and on network change, trusted Wi-Fi networks.
- Automatic updates with Sparkle 2 (EdDSA-signed appcast from `lesha19/KillSwitch-releases`);
  `scripts/release.sh` builds and signs `appcast.xml` and can publish with `--publish`.
- New app icon and template menu bar icons.
- CI on GitHub Actions: build, unit, helper and filter-trust tests.
- Landing page (`docs/index.html`) with an accurate privacy section, and this changelog.

### Changed
- Helper hardening: DNS and rule downloads go through `KS-DNS`, a group of the profile's proxies only;
  server IP rotation re-resolves approved names (never through the LAN's DNS); refresh refuses any change
  to what goes DIRECT; the system resolver is used only on a first import with no tunnel at all.
- When every server moved at once, rotation asks DoH directly: pf lets the core group reach 1.1.1.1 and
  8.8.8.8 on tcp 443 for this only.
- Subscription User-Agent starts with `mihomo/`; device-limit answers become clear errors.
- The app hides the helper's `KS-DNS` group from server lists and pickers.

## [0.7] - 2026-10-10

### Added
- VPN client for our own core: subscription URL (Remnawave or any mihomo/Clash subscription) kept in
  the keychain, auto-update by `profile-update-interval` (default 12 h), traffic and expiry from
  `subscription-userinfo`, Remnawave device headers (`x-hwid` and others).
- Manual servers from share links (vless, trojan, ss, hysteria2, tuic, wireguard).
- WireGuard: wg-quick `.conf` files and `wireguard://` links as manual servers.
- Server list with latency tests, sort by ping and «Лучший» (best server); `ks core proxies`,
  `ks core select`, `ks core delay` talk to the core's controller over a root-only unix socket.
- Connection-first main window, VPN settings tab, keyboard shortcuts and accessibility labels.
- Diagnostics: copy states and recent errors without secrets.
- Warning when another VPN tunnel (Happ, dropweb) comes up next to our core; the watchdog writes it
  to `core/foreign-vpn`.
- Passwordless `ks core refresh` for subscription auto-update; refused (exit 3) when the profile brings
  new server addresses, then the app asks to confirm.
- Release pipeline `scripts/release.sh`: Developer ID signing, hardened runtime, notarization, signed
  and notarized `.dmg`.
- Unit tests for the subscription, share-link and `/proxies` parsers; helper tests for the config
  generator, DNS handling and tunnel detection.

### Changed
- pf: the core's group `_ksvpn` may reach only the servers of its own profile (`servers-core`);
  manually added servers stay open to any process.
- The core config is generated from a fixed template; only `proxies`, `proxy-groups`, `rules` and
  `rule-providers` are taken from the profile. Host names are resolved once and pinned to addresses.
- System DNS for the core is set through the volatile dynamic store (like Mullvad), never the saved
  network preferences, and restored when the core stops.
- The content filter trusts programs by code signature, not by path: our core signed by team
  YR58655PJ7 as `com.lesha19.KillSwitch.core`, Tailscale's app and network extension.
- `Helper/fetch-mihomo.sh` signs the core right after downloading it (`scripts/sign-core.sh`).
- `sudo -n` is tried first everywhere, so allowed commands never prompt.

### Fixed
- Our tunnel (198.18.128.1) is told apart from other VPNs' tunnels.
- `uninstall.sh` switches protection off before stopping the watchdog.

## [0.6] - 2026-10-10

### Added
- Own VPN core: mihomo run by our root daemon as group `_ksvpn`.
- Second layer: content filter system extension (NEFilterDataProvider).

### Fixed
- Filter extension bundle named after its identifier, usage description added.
- Happ servers given by host name; live connections.
- Core: gvisor TUN stack, server and LAN routes kept out of the tunnel, DNS set after start.

## [0.5] - 2026-10-09

### Added
- Helper: server list, direct mode, VPN tunnel detection, watchdog with tamper checks.
- App: server list tab, direct toggle, upgrade button, daemon warning, leak test, macOS update reminder.
- Tailscale DERP relays and control plane reachable away from home.

### Changed
- Every physical network service is disabled at shutdown and re-enabled once rules are loaded,
  closing the boot window.
- VPN tunnel detected by 198.18.0.0/16 instead of the exact 198.18.0.1.

### Fixed
- Upgrade race.

## [0.4] - 2026-10-09

### Added
- Happ support: Happ's servers are detected and let through with one password prompt.

## [0.3] - 2026-10-09

### Added
- Settings; strict default-deny rules; admin password for anything that loosens protection.

## [0.2] - 2026-10-09

### Added
- Install from the window, menu bar icon, widget, app icon, launch at login.

## [0.1] - 2026-10-09

### Added
- Kill switch: pf rules, root helper, LaunchDaemon and window app.
