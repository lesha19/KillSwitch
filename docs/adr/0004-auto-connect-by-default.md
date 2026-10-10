# ADR 0004: auto-connect everywhere by default; trusted Wi-Fi is opt-in

- Status: accepted (0.10)
- Date: 2026-10-10

## Context

«Подключаться автоматически» and «Кроме доверенных сетей Wi-Fi» existed since 0.8, but the first
was off unless the wizard's last step or Settings turned it on (`UserDefaults.bool` defaults to
false). Someone who skipped the wizard's last step, or set the app up before it existed, opened
the lid in a café and was protected but offline («Интернет заблокирован») until they clicked
«Подключить».

The Wi-Fi name comes from CoreWLAN (`CWInterface.ssid()`). Since macOS 14 it is nil unless the
app has Location access (`NSLocationUsageDescription` is in the Info.plist; on macOS only
`authorizedAlways` exists, the When-In-Use request grants it). The app targets macOS 15.

## Decision

- `autoConnect` is **on** when never set (`AutoConnect.enabled(stored:)`); an explicit off from
  the wizard or Settings is kept. Trusted networks stay opt-in (`skipTrusted` off by default).
- A trusted network only means "the VPN does not connect by itself": there the person may stay
  disconnected or pause protection. Nothing ever disconnects or pauses automatically: pausing
  needs the admin password, and an automatic pause would be the app weakening protection by
  itself.
- Without Location access every Wi-Fi is untrusted (fail-safe: the VPN connects); Settings says
  so and offers «Разрешить…» or the Location settings. The Location request is only made from a
  click (turning on trusted networks).

## Consequences

- Existing installs that never touched the switch start auto-connecting after the update. It
  never asks for a password (`coreOnAutomatically`), and an older helper that would need one
  only posts «VPN не подключился сам».
