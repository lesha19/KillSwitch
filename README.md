# KillSwitch

Kill switch for the dropweb VPN (mihomo) on macOS: when it is on, nothing leaves
the Mac through Wi-Fi or Ethernet except the local network and the dropweb core.
If the VPN drops, apps lose internet instead of leaking around the tunnel.
Rules are loaded at boot, before login.

## Parts

- `Helper/killswitch.pf.conf` — pf rules, loaded into anchor `com.apple/killswitch` (`/etc/pf.conf` untouched).
- `Helper/ks` — control script: `status | state | on | off | pause [min] | apply`.
- `Helper/local.killswitch.plist` — LaunchDaemon: applies rules at boot and re-checks every 30 s.
- `Helper/install.sh` — installs the above into `/Library/KillSwitch` (root-owned) and lets the
  installing user run `ks` without a password (only `ks`), so the app works in one click.
- `Helper/uninstall.sh` — removes everything install.sh put in place.
- `App/` — SwiftUI app: window, menu bar icon, install / uninstall from the window (admin password once), launch at login.
- `Widget/` — WidgetKit widget with on/off button. The widget is sandboxed, so its button posts a
  Darwin notification and the running app performs the switch; state reaches the widget through
  the app group `YR58655PJ7.killswitch`.

## How the core is recognised

`DropwebCore` is setuid root + setgid admin, so its sockets carry gid 80. Ordinary apps run
with gid 20 (staff), root daemons with gid 0. pf matches the socket's effective gid, so
`group 80` lets only the core out. No server list to maintain.

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

- Happ and other VPN clients cannot get out while it is on — only dropweb.
- Captive Wi-Fi portals: use pause.
- Tailscale: only direct UDP 41641 and STUN; DERP relays are blocked.
- While the VPN is down, DNS queries to the home router are still allowed (LAN).
