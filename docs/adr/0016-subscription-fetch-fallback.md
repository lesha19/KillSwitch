# ADR 0016: the subscription is fetched through the VPN and a backup link when its host fails

- Status: accepted (Unreleased, issue #11)
- Date: 2026-10-10
- Owner decision 2026-10-10: a backup subscription link entered by the person; no other mirrors
- Research: `docs/research/mullvad-ivpn-gap-2026-10.md` (Mullvad's API access methods)

## Context

The app fetches the subscription with its own `URLSession` (ephemeral). With our core running,
that request goes into the TUN and the profile's rules decide: a host the profile sends DIRECT
(a Russian provider under `GEOIP,RU,DIRECT`) goes around the VPN, and if TSPU blocks it the
update fails although the tunnel works. With the VPN off and protection on, pf drops the request:
nothing can be fetched until the VPN connects. Sparkle fetches the appcast the same way, with its
own session we cannot give a proxy.

Already true and kept: a failed fetch, or a body without servers (`ProfileConverter` throws
`noProxies`, HTML throws `html`), leaves the cached profile and the core's config as they were.

## Decision

- The core's config gets one listener: `{"name":"ks-fetch","type":"http","listen":"127.0.0.1",
  "port":47890,"proxy":"KS-DNS"}` (Helper/ks `FETCH_PORT`). Every connection through it goes to
  KS-DNS, the fallback group over the profile's proxies that never contains DIRECT, so it cannot
  leave outside the tunnel whatever the rules say. No new pf rule. Checked with `mihomo -t` of
  the pinned 1.19.32.
- The app tries `SubscriptionSource.order`: the main link directly, the main link through the
  listener (only while our core runs), then the backup link the same two ways. The first that
  gives a profile wins; if none does, the first error is shown. The source is kept in the status
  and shown under the subscription: «Откуда: основная ссылка через VPN».
- «Резервная ссылка» in Settings › VPN › Подписка: https only, kept in the keychain
  (`subscription-url-backup`) like the main link, masked on screen, never logged.
- A fetch that failed (retry pending) runs again as soon as our VPN connects, and so does an
  update check whose appcast could not be reached (`UpdateRetry`, Sparkle's
  `didFinishUpdateCycleFor` with a URL error): with the tunnel up it goes through it.

## Consequences

- Any local program can use 127.0.0.1:47890 without a password. It only gets the VPN, which it
  already has through the TUN; it cannot reach anything outside the tunnel. It does skip the
  profile's rules (a REJECT or DIRECT rule does not apply to it).
- If another program holds port 47890 the listener does not start and only the fallback through
  the VPN is lost.
- Sparkle itself is never proxied; while the VPN is off and protection on, update checks fail
  until it connects.
- Not verifiable here: the listener on a running core, a real blocked host, Sparkle's retry.
