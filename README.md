# KillSwitch

Kill switch for the dropweb VPN (mihomo) on macOS: when it is on, nothing leaves
the Mac through Wi-Fi or Ethernet except the local network and the dropweb core.
If the VPN drops, apps lose internet instead of leaking around the tunnel.
Rules are loaded at boot, before login.

## Parts

- `Helper/ks` — root helper: generates the pf rules from settings and loads them into anchor
  `com.apple/killswitch` (`/etc/pf.conf` untouched). `status | state | on | off | pause [min] |
  set lan|tailscale|dns|direct|coredirect 0|1 | allow <addr> | unallow <addr> | server-add <ip> |
  server-remove <ip> | core … | apply | watch`. Tests (no root, nothing on the system changes):
  `for t in Helper/tests/*.sh; do bash "$t"; done`.
- `Helper/local.killswitch.plist` — LaunchDaemon: runs `ks watch` (RunAtLoad + KeepAlive), so rules
  are loaded at boot, before login, and checked every 3 s. `AssociatedBundleIdentifiers` makes it
  show up under the app's name in System Settings → Login Items & Extensions.
- `Helper/install.sh [user] [server-ip ...]` / `uninstall.sh` — put everything into root-owned
  `/Library/KillSwitch`. install.sh is safe to re-run: it upgrades the helper in place and keeps
  `settings`, `allow` and `servers`. The app's "Обновить защиту" button does exactly that.
- `Helper/local.killswitch.core.plist` + `Helper/mihomo` (downloaded by `Helper/fetch-mihomo.sh`, pinned
  version and sha256, not in git) — our own VPN core, see below.
- `App/` — SwiftUI app: window, menu bar icon, settings, notifications, install / upgrade / uninstall,
  leak test, and the VPN client for our core: subscription URL (Remnawave or any mihomo/Clash
  subscription, kept in the keychain), auto-update by `profile-update-interval` (default 12 h), traffic
  and expiry from `subscription-userinfo`, servers added from share links (vless, trojan, ss, hysteria2,
  tuic, wireguard) or a wg-quick `.conf`, server list with latency and selection (`ks core proxies` /
  `ks core select`), latency tests and «Лучший» (`ks core delay <group>`), non-secret diagnostics. The subscription
  is fetched with a mihomo User-Agent and Remnawave's device headers (`x-hwid` = hash of the Mac's
  hardware UUID, `x-device-os`, `x-ver-os`, `x-device-model`), reduced to proxies, proxy-groups, rules
  and rule-providers and handed to `ks core import <file.json>`; a failed update keeps the old config.
- `App/Core/` — pure parsers (no AppKit), unit-tested by the `KillSwitchTests` target:
  `xcodegen generate && xcodebuild -scheme KillSwitch test CODE_SIGNING_ALLOWED=NO`.
- `Widget/` — WidgetKit widget with on/off button. It is sandboxed, so its button posts a Darwin
  notification and the running app performs the switch; state reaches it via app group `YR58655PJ7.killswitch`.

Root-owned files in `/Library/KillSwitch`: `settings` (key=value: lan, tailscale, dns, direct, coredirect),
`allow` (addresses reachable by any process), `servers-manual` (VPN server IPs added by `server-add`
and install.sh, reachable by any process), `servers-core` (proxy addresses of the imported core
profile, rewritten on every import, reachable only by our core), `servers` (both merged),
`rules.sha256` and `tunnels` (state of the last load, for tamper checks), `events.log`
(world-readable, last 500 corrective actions).

## Security model

- Default deny on every interface except loopback, AirDrop links and real VPN tunnels. A tunnel is a
  `utun` whose IPv4 address is in 198.18.0.0/16 (dropweb and Happ TUN both use 198.18.0.1), detected
  with `ifconfig` on every load. Other `utun` interfaces (iCloud Private Relay, other VPNs, a
  Tailscale exit node) get nothing. New interface types (iPhone USB, PPP, Thunderbolt) are covered
  automatically.
- VPN server addresses added by hand (`servers-manual`) are reachable by any process. That is needed
  for Happ, whose tunnel runs as the user and cannot be told apart from other apps. Only these
  addresses are open. The servers of our core's profile (`servers-core`) are open to the core only.
- The dropweb core is **not** trusted by default. DropwebCore is setuid root + setgid admin and is
  executable by anyone, so a rule on uid 0 / gid 80 would let any local program start it with its own
  config and escape. The rule exists only with `direct=1` ("Сайты мимо VPN через dropweb"), a weaker mode
  in which the core reaches any address. Without it dropweb still works through its servers; its DIRECT
  rules (Russian sites and so on) do not.
- Own VPN core (`ks core on|off|state|import <json>|refresh <json>|proxies|select|delay`): launchd runs `/Library/KillSwitch/core/mihomo` with
  a root-owned config as uid 0, gid `_ksvpn` (created by install.sh, no members, no setgid binary), and the
  rules let that gid reach only the addresses in `servers`, so a DIRECT rule or proxy in a profile
  cannot leak past the tunnel. `coredirect=1` is the explicit split-tunnel switch: the gid may then reach
  any address and the profile's direct rules (Russian sites and so on) work. `import <json>` takes a
  mihomo profile as a JSON object (the app converts dropweb's newest from YAML) and generates the config:
  only `proxies`, `proxy-groups`, `rules` and `rule-providers` are taken, everything else (TUN, DNS on
  127.0.0.1:53 with DoH resolvers reached through the profile's first group, the controller as a unix
  socket in root-only `core/ctl/`, no listeners or proxy ports) comes from a fixed template. Proxies of
  type direct/dns or unknown types, proxy-providers and file rule-providers are refused (WireGuard
  needs a top-level `server`; pf lets the core reach servers over TCP and UDP); a server given
  by host name is resolved once and pinned to its address (`servername`/`sni` keep the name), and the
  addresses become `servers-core`. `refresh <json>` does the same but is refused (exit 3) when the
  profile brings server addresses that are not in `servers` yet; it is passwordless, for subscription
  auto-update. The app switches servers without the API being exposed: `ks core proxies` (JSON of
  groups and proxies), `ks core select <group> <proxy>`, `ks core delay <group|proxy>` talk to the
  controller socket; names are length- and control-character-checked and fully percent-encoded.
  `Helper/tests/core-config.sh` runs the generator against fixture profiles, attack ones included,
  and checks the result with `mihomo -t`.
  `on` refuses while another VPN tunnel is up, then points the system DNS of every
  physical service to 127.0.0.1; `off` restores it. Like Mullvad, only the volatile dynamic store is
  written (`State:/Network/Service/<id>/DNS` of active and `Setup:/…/DNS` of all services on a
  physical port, ServerAddresses only), never the saved network preferences, so a crash cannot leave
  the Mac without names after a reboot; originals are kept in `core/dns-state` and restored only
  where 127.0.0.1 is still set. The watchdog sets it again when the system overwrites it (DHCP renew,
  network change), restores it when the core has not been running for 5 s or is unloaded, and puts
  back DNS left by older versions (`core/dns-saved`, set with networksetup) once.
  `Helper/tests/dns.sh` checks this against a fake store.
  If Happ or dropweb bring up their own TUN while the core runs (a utun other than ours, 198.18.128.1,
  with a default or /8-or-wider route), the watchdog logs it and writes the interface names to the
  world-readable `core/foreign-vpn` for the app to warn; other programs are not touched.
  Start/stop, proxies/select/delay and refresh are passwordless, import is not.
  Log: `/Library/KillSwitch/core/core.log`.
- Second layer (`Filter/`, optional, Settings → Общие): a content filter system extension
  (NEFilterDataProvider). It cannot see the outgoing interface, so it does not repeat pf: while no VPN
  tunnel is up it drops every new flow except to the LAN, to the addresses pf lets out (servers, Tailscale
  relays, exceptions) and from trusted programs by code-signature path (our core, Homebrew tailscaled,
  DropwebCore with `direct=1`). With a tunnel up it allows everything and leaves the rest to pf. The app
  keeps its lists in sync and turns it on and off with the protection. Signed with Apple Development:
  works on Macs registered in the team, not notarised.
- Tailscale: direct UDP and STUN only for root (system tailscaled); DERP relays and the control plane
  (`tsrelays`, regenerated by `Helper/update-tsrelays.sh`, TCP 80/443 and UDP 3478) for any process, since
  the App Store Tailscale runs as the user; with the Tailscale setting on, the
  tailnet itself (100.64.0.0/10, fd7a:115c:a1e0::/48) is allowed on Tailscale's utun, exit-node traffic is not.
- DNS to LAN resolvers is blocked by default (setting `dns`), so names do not leak via the router.
- Rules and settings are root-owned. Passwordless sudo covers only `ks state`, `ks on`, `ks core
  state|on|off|proxies`, `ks core select|delay …` and `ks core refresh …` (refused if it brings new
  server addresses), none of which can widen the rules; turning off, pausing, `ks core import` and
  every setting change ask for the admin password.
- Watchdog (`ks watch`, every 3 s, honours off / pause): checks that pf is enabled, that the main
  ruleset still references the `com.apple/*` anchor (otherwise reloads `/etc/pf.conf`), that the
  sha256 of the loaded anchor equals the hash saved right after our load, and that the set of tunnel
  interfaces did not change. Any mismatch reloads the rules and is written to `events.log`.
- The app warns (banner and notification) when the daemon is disabled in System Settings → Login Items
  & Extensions or is not loaded, and after a macOS update asks to reboot and re-check.
- Settings → "Проверка": tries `curl --interface en0` (and the default-route interface) to 1.1.1.1 as an
  ordinary user; a reply means a leak. It also shows the external IP and the tail of `events.log`.

What it does not protect against: anything already running as root (it can unload pf; the watchdog
restores the rules within 3 s and logs it, but this is detection, not prevention); the seconds of boot
before the LaunchDaemon runs (only system daemons are up then); dropweb's own rules in `direct=1` mode;
LAN hosts that act as proxies; anything that can reach a listed VPN server, if the server itself relays.

## Install

```bash
xcodegen generate
xcodebuild -project KillSwitch.xcodeproj -scheme KillSwitch -configuration Release -derivedDataPath build -allowProvisioningUpdates build
cp -R build/Build/Products/Release/KillSwitch.app /Applications/
```

Then open the app and press "Установить защиту" (or run `Helper/install.sh` in Terminal; server
addresses found in dropweb and Happ configs are passed to it). After updating the app, press
"Обновить защиту" to upgrade the installed helper.

## Emergency off

```bash
sudo pfctl -a com.apple/killswitch -F all
```

## Known limits

- Happ's direct sites (Russian, Apple, Steam) do not open while it is on: only VPN server addresses are open.
- Captive Wi-Fi portals: use pause.
- Tailscale: direct UDP only from system tailscaled; the App Store app goes through DERP relays away from home.
  Exit nodes are blocked. If Tailscale adds relays, run `Helper/update-tsrelays.sh` and "Обновить защиту".
- VM networks outside private ranges (e.g. OrbStack 198.19.0.0/16) are blocked.
- iCloud Private Relay can bypass the filter: turn it off.
- After every macOS update reboot the Mac and run the leak test; system updates may replace `/etc/pf.conf`
  or change how pf behaves.
- At boot, protection starts when launchd starts the daemon; for full protection switch Wi-Fi off before
  shutting the Mac down.
- If the daemon is switched off in System Settings, the rules stay but nothing watches them.
