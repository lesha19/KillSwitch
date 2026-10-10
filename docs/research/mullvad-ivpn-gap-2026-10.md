# Mullvad / IVPN vs KillSwitch: gap analysis (2026-10-10)

Scope: desktop (macOS) apps. KillSwitch is a client for the user's own VLESS/Reality (and other
mihomo-supported) subscription, not a provider. Hence provider things (accounts, server ownership,
WireGuard key rotation, devices, own servers, port forwarding) are N/A or must be adapted.

Sources (all fetched 2026-10-10; the Mullvad changelog was read up to char 100000 of 147509, so
entries before 2020.4 and a tail are not covered):
- Mullvad changelog: https://raw.githubusercontent.com/mullvad/mullvadvpn-app/main/CHANGELOG.md
- Mullvad app guide: https://mullvad.net/en/help/using-mullvad-vpn-app
- Mullvad help index: https://mullvad.net/en/help/tag/mullvad-app
- Mullvad macOS split tunnel: https://mullvad.net/en/blog/2025/1/10/split-tunneling-on-macos
- IVPN changelog: https://raw.githubusercontent.com/ivpn/desktop-app/master/CHANGELOG.md
- IVPN macOS page: https://www.ivpn.net/en/apps-macos/
- IVPN split tunnel FAQ: https://www.ivpn.net/knowledgebase/general/split-tunnel-faq/
- IVPN AntiTracker FAQ: https://www.ivpn.net/knowledgebase/general/antitracker-faq/
- IVPN firewall exceptions: https://www.ivpn.net/knowledgebase/general/firewall-exceptions/
- IVPN repo: https://github.com/ivpn/desktop-app
- Unverified (page not fetched / from memory, marked "?"): IVPN V2Ray/obfs4 details, IVPN trusted-network
  rules detail, Mullvad content-blocker category list (changelog: ads, trackers, malware, adult,
  gambling, social media).

## 1. What KillSwitch already does (0.14.2, from README, CHANGELOG, ADR 0001-0012, spec, audit)

- pf kill switch in a root LaunchDaemon (`ks watch`): rules loaded at boot before login, checked every
  2 s; default deny, tamper checks, IPv6 blocked (ADR 0003), emergency off, pause (5/30 min, custom).
- Allow home LAN (`lan`), Tailscale, DNS-to-router option, "disconnect network on Mac shutdown",
  address allow-list ("Адреса без VPN"), per-server exceptions for other VPN apps.
- Own mihomo core as root daemon, TUN, fixed config template, all DNS through the tunnel (KS-DNS group),
  server IP pinning + rotation watchdog + DoH bootstrap; DIRECT rules need admin approval.
- Subscription (Remnawave/Clash), auto-refresh, traffic/expiry, HWID headers, share links, WireGuard/AmneziaWG import.
- Server list with latency, "Лучший", auto-failover within a country (ADR 0005), per-server transport
  overrides: TLS fingerprint, multiplexing (ADR 0007).
- Split tunnel by app (`splitapps`), RU-direct geosite/geoip; Double VPN (multihop via dialer-proxy);
  ad/tracker blocking (`GEOSITE,category-ads-all,REJECT`, 0.13).
- Foreign VPN detection and replacement on request (ADR 0009), network cause probe: no internet /
  white-lists / blocked servers (ADR 0006), leak test (IPv4/IPv6/DNS), non-secret diagnostics copy.
- Auto-connect everywhere by default + trusted Wi-Fi opt-out (ADR 0004), launch at login (SMAppService),
  notifications (reconnect, expiry, pause end, protection off), menu bar status item with right-click
  menu and optional live speed, widget, App Intents/Shortcuts (connect, disconnect, change country, status).
- Privileged XPC daemon with authorization right (Touch ID / password cached a few minutes, ADR 0010),
  AdminGate, NEFilter system extension as second layer (issue #7), Sparkle seamless updates
  (ADR 0012), signed + notarized, single-window UI (ADR 0008), security audit 2026-10.
- Open GitHub issue: #8 "Routing only from the subscription + full traffic transparency"
  (remove app-injected RU rules; show every rule, rejected rules, live connections with process/rule/exit).
  Issues #1-#7 closed.

## 2. Feature table

Effort: S (<1 day), M (days), L (week+). Priority: H/M/L/- (not needed).

| Feature | Mullvad | IVPN | KillSwitch now | Applicable? | Effort | Prio |
|---|---|---|---|---|---|---|
| Always-on kill switch | Always on, cannot be disabled (blocks while connecting/reconnecting) | Firewall on-demand or always-on, blocks DNS/IPv6/disconnect leaks | pf boot-time deny, tamper watchdog; off/pause need auth | Yes, KS is stronger (boot) | done | - |
| Lockdown mode (also block after manual Disconnect/Quit) | Optional "Lockdown mode" (formerly always require VPN); auto-on if settings fail to parse | "Always-on firewall" | After "Отключить" VPN, protection stays (dead internet) unless off; equivalent | Yes, exists | done | - |
| Fail-closed on corrupt settings | `MULLVAD_LOCKDOWN_ON_INVALID_SETTINGS`, locks down on parse failure | ? | `ks` regenerates; behaviour on corrupt `settings` not documented | Yes: add test "corrupt settings -> deny all" | S | M |
| Allow LAN / local network sharing | Toggle, private ranges | Toggle | `lan` toggle, IPv4 only, AirDrop/link-local always | Yes | done | - |
| Firewall exceptions (IP/subnet bypass) | Not in app (static routes doc) | Settings>Firewall>Exceptions (needs static route) | "Адреса без VPN" list | Yes | done | - |
| Pause VPN | No | Pause | Pause 5/30 min + "до переподключения" | Yes | done | - |
| DNS: custom resolver | IPv4/IPv6 only, no DoH/DoT | Multiple custom DNS (3.15), DoH support | Fixed template: DoH via tunnel; no user choice | Adapt: let user pick resolver (DoH URL list) inside tunnel; must stay through KS-DNS | M | M |
| DNS content blockers (categories) | Ads, trackers, malware, adult, gambling, social media (toggles) | AntiTracker lists | One switch: ads+trackers via `category-ads-all` | Adapt: add geosite categories already in shipped `geosite.dat` (e.g. porn, gambling; malware/social need check). Pure rule additions, no pf change | S-M | M |
| AntiTracker "Hardcore" (block Google/Meta) | n/a | Hardcore mode | no | Possible via geosite google/facebook REJECT; niche, breaks sites; low value for RU users | S | L |
| Multihop (entry/exit) | Yes, any entry+exit | Yes | "Двойной VPN" (entry picked, exit = chosen server) | Yes | done | - |
| Obfuscation: UDP-over-TCP, Shadowsocks, QUIC, LWO | All for WireGuard, auto-fallback when connection fails (QUIC since 2025.9, LWO 2025.13) | obfs4 + V2Ray ? | Core speaks VLESS/Reality/hy2/tuic/ss/trojan from subscription; fingerprint & mux overrides | N/A mostly (server side fixed by subscription). Adapt: auto-cycle transport overrides on failure ("try other fingerprint/mux automatically") | M | M |
| Automatic protocol fallback | App cycles obfuscation until connected | ? | Failover across servers in a country; no auto transport cycling | Yes (see above) | M | M |
| DAITA (traffic-analysis defence) | DAITA v2, auto multihop to capable servers | none | no | N/A: needs server-side support in WireGuard relays; not in mihomo | - | - |
| Quantum-resistant tunnel | PQ key exchange (ML-KEM + HQC since 2025.7), default | Quantum-resistant WireGuard | no | N/A (VLESS/Reality, mihomo lacks PQ handshake) | - | - |
| Split tunneling | macOS since 2024.4/2025 (needs Full Disk Access) | Win/Linux/Android only; **not macOS**; inverse mode Win/Linux | By app (`splitapps`) via mihomo process rules, warning on writable apps | Yes, done; inverse mode ("only these apps via VPN") is missing | M | L |
| Server filters: ownership, provider | Yes | no | Subscription groups only | N/A (provider concept). Adapt: filter by protocol/country/group | S | L |
| Custom lists of locations | Yes (2023.6) | no | no | Yes: favourite servers / pinned countries | M | M |
| Recent selections, search bar, context menu on locations | Yes (2023.1 search, 2026.3 recents) | server list, latency | Server list with latency and flag; search? not documented | Yes: search + recents + favourites | S | M |
| Default location from current country | 2026.2 | ? | no | Weak value | S | L |
| Latency/speed picker, fastest | Latency shown; fastest = Automatic | `-f` fastest in CLI | Latency + "Лучший" | Yes | done | - |
| Auto-connect on launch | Yes (off by default) | On launch / insecure Wi-Fi | On by default everywhere (ADR 0004) | Yes | done | - |
| Trusted / untrusted Wi-Fi rules | No | Trusted networks, auto connect/disconnect rules | Trusted opt-out, needs Location | Yes; IVPN lets per-network rules, KS only "trusted = no auto-connect" | done / S for per-network | L |
| Launch at login | Yes | Yes | SMAppService | Yes | done | - |
| Start minimized, unpin window, monochrome tray icon, animate map | Yes | ? | Status item popover; options not documented | Cosmetic: mono icon + unpin window | S | L |
| Notifications; critical ones always | Toggle; critical always shown | ? | Four toggles | Yes | done | - |
| Tray tooltip with connection info; notification dot | Yes | ? | Menu bar speed optional | S: tooltip with server/country/IP | S | L |
| API access methods for the app's own API (censorship) | Direct, bridges, Encrypted DNS proxy, domain fronting (unreleased 2026), custom Shadowsocks/SOCKS5 | ? | Subscription URL fetched directly; if sub host blocked in RU and VPN down, update fails (not verified in code) | Adapt: fetch subscription via running tunnel (or last-known-good mirror, user-set proxy) when direct fails; also Sparkle appcast | M | H |
| Custom bridge / import-export settings | `mullvad export-settings`, `import-settings`, `reset-settings`, server IP overrides | ? | none | Yes: export/import (without secrets) + reset | M | M |
| CLI | `mullvad` full CLI, `--json` status, `anti-censorship`, log level | `ivpn` CLI, `-f` fastest, bash completion | `ks` is root helper (sudoers), not a user CLI; Shortcuts exist | Yes: user-facing `killswitch` CLI via XPC (status --json, connect, disconnect, pause) | M | M |
| Status / events for scripting | `mullvad status --json`, listen | CLI status | App Intents (status), no JSON | See CLI | S (with CLI) | M |
| IPv6 | In-tunnel IPv6 toggle, IPv4/IPv6 to relay | IPv6 leak protection | Blocked by design (ADR 0003) | Keep blocked; optional IPv6-in-tunnel only if sub supports it | L | L |
| MTU setting + auto-detection | Yes (default 1380; auto test on connect) | Via WG settings ? | Template value; not exposed | Expose TUN MTU for troubleshooting (mihomo `tun.mtu`) | S | L |
| Port selection | WireGuard port, UDP2TCP ports | Port picker, multiple ports | Server-defined | N/A | - | - |
| Account, devices, key rotation, port forwarding | Yes | Yes (WG key rotation, device mgmt) | Subscription + HWID | N/A (adapt: device limit error already shown) | - | - |
| Beta channel | In-app beta opt-in | beta builds | One Sparkle feed | Yes: Sparkle channel "beta" | S | M |
| In-app updates | Yes (2025.8) | auto-update | Sparkle seamless, daemon upgrade | Yes | done | - |
| Problem report (anonymized logs) | In-app form with logs | ? | "Скопировать диагностику" + `events.log` | Adapt: one-click export zip (no secrets) to attach to a support message | S | M |
| Leak test | Link to mullvad check | ? | Built-in leak test (public IP, DNS, IPv6) | Yes | done | - |
| Connection health / auto-recovery | Reconnect on network change | WireGuard health checks (3.15.15), faster recovery on macOS | Watchdog, network-change re-resolve, failover | Yes | done | - |
| Protocol choice (WG/OpenVPN) | WG only since 2025.14 | WG + OpenVPN | Whatever subscription gives | N/A | - | - |
| Another VPN detection | Docs warn | firewall exceptions to run corporate VPN | Detect, name, replace (ADR 0009) | Yes, ahead | done | - |
| Widgets / Shortcuts | no | no | Widget + App Intents | KS ahead | done | - |
| Language | Many (Ukrainian 2026.4) | ? | Russian only | Add English strings (xcstrings exists) | M | M |
| Hardening: no keychain access, authenticated local clients | daemon auth | 3.15.15 fixes (crash by unauthenticated client) | Audit KS-01..08, XPC right | Done; recheck XPC peer validation periodically | S | L |

## 3. Notes on specific rows

- Mullvad lockdown vs KillSwitch: Mullvad's kill switch cannot be switched off; KillSwitch protection can be
  paused/turned off behind auth, which fits a self-hosted client. No change needed.
- IVPN split tunnel is not offered on macOS (per its FAQ), so only Mullvad is the reference there.
- Mullvad's anti-censorship ladder (UDP2TCP, Shadowsocks, QUIC, LWO, auto-fallback) replaces what KillSwitch
  gets for free from VLESS/Reality; the transferable idea is automatic escalation, not the protocols.
- Mullvad's "API access methods" is the closest thing to a real gap for Russian users: the app's own control
  channel (subscription URL, appcast, geodata) can be blocked just like the VPN.
- Issue #8 (transparency of rules/connections) goes beyond anything in Mullvad/IVPN desktop apps and
  is not repeated here.

## 4. Ranked list of what is worth implementing

1. Subscription (and appcast) fetch fallback ("access methods" analogue): retry through the live tunnel,
   cached last good profile, optional user mirror/proxy. M, H.
2. Automatic transport escalation on failure (fingerprint -> mux -> next server) building on ADR 0005/0007. M, M.
3. User-facing CLI (`killswitch status --json | connect | disconnect | pause`) over the existing XPC daemon. M, M.
4. Favourites + recents + search in the server list (Mullvad custom lists / recent selections). M, M.
5. More content-blocking categories (porn, gambling, malware, social) from shipped geosite, plus a
   user-defined custom DNS/DoH choice that stays inside KS-DNS. S-M, M.
6. Problem report export (zip of diagnostics + events.log, secrets stripped) and settings export/import/reset. S-M, M.
7. Sparkle beta channel toggle. S, M.
8. Fail-closed test for corrupt `settings`; English localisation. S / M, M.
9. Cosmetic/low: tray tooltip, monochrome icon, unpin window, MTU field, inverse split tunnel, per-network trusted rules. S-M, L.

Not worth it / N/A: DAITA, quantum-resistant tunnels, ownership/provider filters, port selection, accounts,
devices and key rotation, OpenVPN, WG-specific obfuscation (UDP2TCP/QUIC/LWO), AntiTracker hardcore (breaks sites),
in-tunnel IPv6 (conflicts with ADR 0003).
