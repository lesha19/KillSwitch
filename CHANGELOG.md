# Changelog

All notable changes to KillSwitch are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) (0.x: no stability promise).

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
