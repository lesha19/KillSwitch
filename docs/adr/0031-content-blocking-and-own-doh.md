# 0031. Content blocking by category and the own DNS-over-HTTPS server

Status: accepted — decided by the agent, the owner may change it (#14, 2026-10-11).

## Context

#14 asks for Mullvad/IVPN-style blocking (ads, trackers, malware, adult, gambling, social) and the
user's own DoH server, without ever letting DNS or traffic out of the tunnel. Roadmap #43 sets the
default: built-in categories from geosite, no paid lists. Since 0.13 one switch, `adblock`, puts
`category-ads-all` of the shipped, sha256-pinned `geosite.dat` first as REJECT (mihomo) /
blackhole (Xray). The VPN must never drop and traffic must never leak (ADR 0013, 0017).

## Decision

**Categories** — only lists that exist in the shipped geosite.dat (meta-rules-dat pinned in
`Helper/fetch-geodata.sh`, checked by reading the file). Each is a 0|1 setting, like `adblock`:

| setting        | list                         | in the file (2026-10-10 build)                     |
|----------------|------------------------------|----------------------------------------------------|
| `adblock`      | `category-ads-all`           | ads and trackers (Google Analytics, Яндекс.Метрика) |
| `blockadult`   | `category-porn`              | adult sites                                        |
| `blocksocial`  | `category-social-media-!cn`  | VK, OK, Facebook, Instagram, X, LinkedIn… (no Telegram) |
| `blockbetting` | `category-betting-ru`        | Russian bookmakers only (13 domains)               |

There is no malware or phishing list in meta-rules-dat; none is offered (no paid or downloaded
lists). A separate "trackers" switch is not offered either: `category-telemetry` holds 6 GitHub
and Mozilla hosts, and the trackers worth blocking are already in `category-ads-all`.

`adblock` keeps its key and meaning, so nothing migrates and an upgrade asks no password. Every
category is refused before the subscription's rules (REJECT / one blackhole rule), so the DIRECT
signature, egress and pf stay as they are; changing one rebuilds the config and needs the
administrator, as `adblock` always did. Without geosite.dat there is no rule.

**Own DoH** — `ks set doh <url>` (`doh=` in settings, "" clears). Accepted: `https://`, a public
host name or IPv4 address, optional port and path (`[A-Za-z0-9._~%/-]`); no user, query or
fragment; no loopback, private, link-local, CGNAT, 198.18/15 or multicast address, no `.local`
names; at most 256 bytes. The same check in ks (`valid_doh`, also for the settings file — a bad
line blocks everything, ADR 0015) and the app (`HelperCommand.isDoH`).

- mihomo: `nameserver: [<url>#KS-DNS]`, `fallback: [1.1.1.1, 8.8.8.8 DoH #KS-DNS]` with
  `fallback-filter: {geoip: false}` — the fallback is asked only when the own server gives no
  answer. Its name is resolved by `default-nameserver` (our DoH through KS-DNS). With fake-ip,
  sites that go through a VPN server are resolved by that server; the own DoH answers what the
  core resolves itself (address rules, DIRECT, the subscription's `fake-ip-filter`).
- Xray: the server `{address: <url>, tag: ks-doh}` goes first in `dns.servers`; the template's
  servers follow (Xray asks the next one on failure; `disableFallback` is dropped and reported).
  Without template servers, Cloudflare's DoH (also tagged `ks-doh`) follows. Two of our rules,
  before the subscription's, send `inboundTag ks-doh` and the host (`full:<host>` or its address)
  to a VPN server. The template's domain-specific servers (e.g. Yandex for `category-ru`) stay its
  policy, as with mihomo's `nameserver-policy`.
- Both: added after the DIRECT signature; no address enters pf; refresh asks nothing new. The
  world-readable report, events.log and the report's DNS list show only the host (a DoH path can
  hold an account id). An invalid stored value is ignored by the generator (our resolvers).

Fail-safe: the own server is never queried outside the tunnel, and when it fails the core falls
back to the configuration's resolvers through the VPN — never the ISP's or the LAN's resolver.
A DoH server that answers NXDOMAIN for what it blocks may be overruled by the fallback; staying
connected wins over that filter.

## Consequences

- Settings › Дополнительно «Блокировка»: four switches; «Свой сервер DNS-over-HTTPS» with a sheet.
- Settings transfer (ADR 0024) carries the three new switches and `doh`; the daemon takes them.
- Live check needed: the Xray DNS tag routing and mihomo fallback against a real DoH server and a
  dead one, on the owner's subscription.
