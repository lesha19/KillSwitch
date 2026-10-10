# DoodleVPN subscription vs StorkVPN (2026-10-10)

Studied a DoodleVPN subscription (Remnawave panel, `ddlvpn.lol`) fetched with Happ, mihomo,
v2rayN and Clash Verge User-Agents. Without `X-HWID` it returns a "Device identification
required" stub; with a test HWID (`ks-research-…`, one device slot used on the owner's Doodle
account) it returns 8 configs. Secrets (UUIDs, keys) were not recorded.

## What Doodle ships

| Area | Doodle | StorkVPN |
|---|---|---|
| Configs | 8: Auto, Germany, USA, Netherlands, "Russia YouTube without ads", Germany reserve, 2 × whitelist bypass | 1: Lithuania |
| Germany config | 7 entries, all via Russian bridges (Baxet, Aeza, Datacheap VPS), Reality SNI `www.ozon.ru` / `www.yandex.ru`, leastLoad balancer | direct to LT |
| Whitelist bypass (mobile) | VLESS xHTTP+TLS through a Russian CDN (`cdn.vkstream.cloud`, tag "yandex"), VLESS WS+TLS via Selectel; geosite/geoip `whitelist` direct; remaining quota in the name ("1 ГБ осталось") | none (RU1 retired 2026-07) |
| Auto | xHTTP on 7443 primary, TCP Vision fallback, observatory every 30 min over 6 servers | TCP primary, xHTTP fallback, burstObservatory 90 s |
| Reality SNI | other people's sites (tradingview, ozon) | own selfsteal site (better) |
| Direct rules | `geosite:category-ru` + `geoip:private` only | explicit domain lists (more precise) |
| Fingerprint | firefox | chrome |
| Policy | uplinkOnly 2 / downlinkOnly 5 (old defaults) | 0 / 0 as Xray docs advise |
| DNS | DoH per outbound via inbound tags, Yandex `tcp+local` for RU domains | similar |
| Mihomo profile | weak: `mode: global`, one `MATCH` rule, no sniffer, no RU DNS | 210-rule template (better) |
| Headers | profile-title, announce, support-url, profile-update-interval 3, subscription-userinfo | check ours |

## Takeaways (owner lives in Belarus, single user — 2026-10-10)

- Not needed: Russian bridges, whitelist bypass, quota in names.
- Taken: community-maintained direct lists (MetaCubeX `category-ru`, `category-gov-ru`,
  `geoip/ru`, `geoip/by`) + `.by`/`.бел` direct + BY DNS via Yandex → mihomo template proposal in
  `~/проекты ai/настройка нод/vpn/proposals/mihomo-template-match-happ-20261010/` (not yet applied
  to the panel; `apply.sh`).
- Finding: Remnawave 3.4.x emits xHTTP proxies into Mihomo subscriptions
  (`mihomo.generator.service.ts`, `UNSUPPORTED_TRANSPORTS = {'kcp'}`), so the LT xHTTP fallback can
  reach KillSwitch.
- Ideas kept for later: firefox fingerprint as a fallback (#20), subscription headers (#22).
