# KillSwitch

Kill switch for the dropweb VPN (mihomo) on macOS: when it is on, nothing leaves
the Mac through Wi-Fi or Ethernet except the local network and the dropweb core.
If the VPN drops, apps lose internet instead of leaking around the tunnel.
Rules are loaded at boot, before login.

## Parts

- `Helper/ks` — root helper: generates the pf rules from settings and loads them into anchor
  `com.apple/killswitch` (`/etc/pf.conf` untouched). `status | state | on | off | pause [min] |
  set lan|tailscale|dns 0|1 | allow <addr> | unallow <addr> | apply`.
- `Helper/local.killswitch.plist` — LaunchDaemon: applies rules at boot (before login) and re-checks every 30 s.
- `Helper/install.sh` / `uninstall.sh` — put everything into root-owned `/Library/KillSwitch`.
- `App/` — SwiftUI app: window, menu bar icon, settings, notifications, install / uninstall.
- `Widget/` — WidgetKit widget with on/off button. It is sandboxed, so its button posts a Darwin
  notification and the running app performs the switch; state reaches it via app group `YR58655PJ7.killswitch`.

## Security model

- Default deny on every interface except loopback, tunnels (utun*) and AirDrop links. New
  interface types (iPhone USB, PPP, Thunderbolt) are covered automatically.
- The dropweb core is let out by socket credentials **uid 0 and gid 80** together: DropwebCore is
  setuid root + setgid admin. A user process cannot get uid 0 (so `newgrp admin` does not help),
  root daemons have gid 0. A scan of /Applications, /Library, /opt and ~/Library found no other
  binary that is both setuid root and setgid admin.
- Tailscale direct UDP and STUN are allowed only for root (system tailscaled), so a user process
  binding port 41641 gets nothing.
- DNS to LAN resolvers is blocked by default (setting `dns`), so names do not leak via the router.
- Rules and settings are root-owned. Passwordless sudo covers only `ks state` and `ks on`; turning
  off, pausing and every setting change ask for the admin password.

What it does not protect against: anything already running as root (it can unload pf); the
seconds of boot before the LaunchDaemon runs (only system daemons are up then); dropweb's own
rules (DIRECT rules and its local proxy go out by design); LAN hosts that act as proxies.

## Install

```bash
xcodegen generate
xcodebuild -project KillSwitch.xcodeproj -scheme KillSwitch -configuration Release -derivedDataPath build -allowProvisioningUpdates build
cp -R build/Build/Products/Release/KillSwitch.app /Applications/
```

Then open the app and press "Установить защиту" (or run `Helper/install.sh` in Terminal).

## Emergency off

```bash
sudo pfctl -a com.apple/killswitch -F all
```

## Known limits

- Happ and other VPN clients cannot get out while it is on — add their server addresses to exceptions.
- Captive Wi-Fi portals: use pause.
- Tailscale: only direct UDP from system tailscaled; DERP relays are blocked.
- VM networks outside private ranges (e.g. OrbStack 198.19.0.0/16) are blocked.
