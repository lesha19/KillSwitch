# Changelog

All notable changes to KillSwitch are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) (0.x: no stability promise).

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
