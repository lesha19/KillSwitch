# Multi-core research: mihomo, Xray-core, sing-box (2026-10-10)

Status: research, nothing decided. Question from the owner: a "Swiss army knife" client that supports
as many cores and protocols as reasonably possible. Read-only study; no code changed.

Method note: facts below come from the GitHub trees/APIs and docs read on 2026-10-10 (URLs at the end).
Context7 was not used: its index lags the 2026 releases of all three cores, so source trees were read
directly. Items marked **(verify)** were not confirmed against a running binary.

## 1. How KillSwitch runs its core today (what any new core must fit)

- **Core**: `Helper/mihomo` v1.19.32 (pinned by `Helper/fetch-mihomo.sh`, sha256), 57 MB, re-signed by us as
  `com.lesha19.KillSwitch.core` (`scripts/sign-core.sh`), shipped in the app's `Resources/Helper`, copied by
  `install.sh` (`core_update`) to `/Library/KillSwitch/core/mihomo`. LaunchDaemon `local.killswitch.core`,
  `UserName root`, `GroupName _ksvpn`, restarted by `launchctl kickstart -k` only when binary/geodata/plist change.
- **Config**: the app turns the subscription (mihomo YAML, or base64 links via `ProxyLink`) into a reduced
  mihomo-profile JSON (`ProfileConverter`: only `proxies`, `proxy-groups`, `rules`, `rule-providers`).
  The root helper `ks core import` (`core_generate`, ~bash + plutil + perl) validates it against the
  whitelist `PROXY_TYPES='ss|ssr|vmess|vless|trojan|hysteria|hysteria2|tuic|wireguard|snell|http|socks5|ssh|mieru|anytls'`,
  pins server host names to IPv4 (pf works on addresses), strips `interface-name`/`routing-mark`, applies
  `x-ks-overrides` (ADR 0007), and writes the *whole* config itself: gvisor TUN with `auto-route`,
  fake-ip DNS on 127.0.0.1:53, `route-exclude-address` = LAN + every server IP, controller on a unix socket
  (`ctl/mihomo.sock`, root-only dir). The subscription can never set ports, controller, tun or dns.
- **Policy that is mihomo-shaped**: `direct_sig` (which groups/rules/providers can send traffic DIRECT; a change
  needs a password), failover via `fallback`/`url-test` groups (ADR 0005), split-tunnel by `PROCESS-PATH-REGEX`
  / `PROCESS-NAME` rules, `GEOSITE,category-ru`, `GEOIP,RU`, ad blocking via `GEOSITE,category-ads-all`, stats and
  server selection via the REST API through `ks core proxies|select|delay|traffic`.
- **Kill switch** (pf anchor, `ks rules`): default-deny; the core's sockets pass because pf matches the
  **socket's group `_ksvpn`** (`as_core_group`), VPN tunnels are recognised as utun with an address in
  198.18.0.0/16 (ours is `198.18.128.1`, `CORE_TUN_ADDR`), servers are in the `servers` file. This is **core-agnostic**
  as long as (a) the new process runs with gid `_ksvpn`, (b) its TUN gets an address in 198.18/16 distinguishable
  from other VPNs, (c) its server addresses are in `servers`.
- **Content filter** (`Filter/TrustedCode.swift`): lets flows out only for code with `identifier
  "com.lesha19.KillSwitch.core"` + our team OU. **Every additional core binary needs its own signed identifier
  and a new `TrustedCode.Program` case.**
- **Subscription fetch**: `SubscriptionHeaders.userAgent` = `mihomo/1.19.32 (KillSwitch/..)`; Remnawave answers
  mihomo YAML for that. Remnawave has four template families: Mihomo, Base64, Xray-json, Sing-box
  (docs.rw/learn-en/templates; the panel picks one from the client request, UA rules, or per-squad templates).
  The same URL with a different UA gives a different native format. **(verify the exact UA/route per format on the
  StorkVPN panel; its Caddy filters UAs.)**
- Distribution: Developer ID, notarized, Sparkle. Nested binaries must be Developer-ID-signed with hardened runtime.

## 2. Protocol x core matrix (mihomo 1.19.32, Xray-core 26.x, sing-box 1.14.3)

Y = supported, P = partial/with caveat, - = no. Based on `adapter/outbound` + `transport` trees (mihomo v1.19.32),
`proxy/`, `transport/internet/` trees (Xray main), `protocol/`, `transport/` (sing-box testing) and release notes.

| Protocol / feature | mihomo | Xray | sing-box | Note |
|---|---|---|---|---|
| VLESS + TLS | Y | Y | Y | |
| VLESS + REALITY | Y | Y | Y | **version byte**: mihomo sends 1.8.2 (`component/tls/reality.go`), sing-box 1.8.1 (`reality_client.go`), Xray sends its own (26.x). A server with `minClientVer` > 1.8.2 rejects both mihomo and sing-box. Only Xray satisfies it. |
| VLESS XTLS-Vision (flow) | Y | Y | Y | |
| VLESS encryption (ML-KEM post-quantum, `encryption=`) | Y (`transport/vless/encryption`) | Y (origin) | - **(verify)** | |
| xHTTP transport | Y (`transport/xhttp`: modes auto/packet-up/stream-up/stream-one, session/seq/padding placements, xmux = `reuse-settings`, `download-settings`, h3 via `alpn:[h3]`, HTTP/1.1; ~23 fields kebab-cased, ported from Xray) | Y (reference; widest feature set, fastest to get new knobs) | **-** (no xhttp/splithttp in the transport list or changelog) | mihomo lags Xray on new xhttp knobs by weeks-months; check per feature. |
| Finalmask (fragment TCP, noise UDP, header-custom, Sudoku, XDNS/XICMP, udphop, XHTTP/3 + masks, `fm` share param) | **-** (no fragment option, see ADR 0007) | **Y** (since v26.3.27; fields still change: v26.7.28 reworked XMC, v26.9.9 split `udphop`) | P (own TLS `fragment`, `record_fragment`; not the same masks) | Main reason to want Xray. Fast-moving, breaking. |
| ECH | Y (`ech-opts`) | Y | Y | |
| VMess (+ws/grpc/h2/httpupgrade) | Y | Y | Y | |
| Trojan | Y | Y | Y | |
| Shadowsocks / SS-2022 | Y | Y (`shadowsocks_2022`) | Y | |
| ShadowTLS v1-3 | Y | - | Y | |
| Hysteria2 (+salamander, port hop) | Y (`ports`, `hop-interval`, obfs) | Y (client + inbound since v26.3.27) | Y | |
| Hysteria v1 | Y | P (as Hysteria 2 only) | Y | |
| TUIC v5 | Y | - | Y | |
| WireGuard | Y | Y (+FullCone since 26.3.27) | Y (endpoint) | |
| AmneziaWG (v1, 1.5, 2) | **Y** (`amnezia-wg-option`: jc/jmin/s1-s4/h1-h4/i1.., via metacubex/amneziawg-go) | - | - (**verify**; forks only) | standalone amneziawg-go (MIT) is an alternative only if mihomo's lags. |
| AnyTLS | Y | - | Y | |
| Mieru | Y | - | - | |
| SSH | Y | - | Y | |
| Snell | Y | - | Y | |
| SOCKS5 / HTTP | Y | Y | Y | |
| MASQUE (HTTP/3 CONNECT-UDP/IP) | Y | Y (`proxy/masque`) | Y | new in all three |
| TrustTunnel, Sudoku, ShadowQUIC, JLS, Restls, TLS-mirror, Gost relay | Y (present in v1.19.32 tree) | Sudoku only (as finalmask) | - | not in `PROXY_TYPES`; add after review |
| NaiveProxy | - | - | **Y** (since 1.13; Chromium network stack, QUIC/ECH) | only sing-box |
| OpenVPN / OpenConnect | Y (openvpn) | - | Y (openvpn, openconnect) | |
| Tailscale / ZeroTier / EasyTier as outbound | Y but behind build tags (`tailscale`,`zerotier` stubs; **verify what the release binary includes**) | - | Y (tailscale) | We already let Tailscale pass in pf; do not mix. |
| Juicity | - | - | - | upstream (AGPL-3.0) last pushed 2025-06; dead, skip |
| Tor | - | - | Y | out of scope |
| TUN on macOS | Y (gvisor/system/mixed; current use) | **Y, young** (`proxy/tun/tun_darwin.go`; auto routes via `autoSystemRoutingTable`; **does not set system DNS on macOS**; default address 169.254.10.1/30 unless `gateway` set) | Y (mature; auto_route, strict_route, stack gvisor/system/mixed) | |
| fake-ip DNS | Y | P (`fakedns`) | Y | KillSwitch relies on mihomo's fake-ip + 127.0.0.1:53. |
| Process rules (per-app split tunnel) | Y (`PROCESS-PATH-REGEX`, `find-process-mode`) | **-** on macOS **(verify)** | Y (`process_path`) | ADR split-tunnel feature depends on it. |
| Failover groups | Y (fallback/url-test/load-balance) | Y (balancers + observatory) | Y (urltest/selector) | |
| Control/stats API | REST + WS, **unix socket** (used) | gRPC StatsService via `api` inbound (query stats, no per-connection list) | Clash API (REST, TCP; **no unix socket documented, verify**) or v2ray_api (gRPC, build tag) | Per-connection list and delay tests exist only in mihomo/sing-box. |
| License | **GPL-3.0** (GitHub UI shows "MIT": wrong, LICENSE file is GPLv3) | MPL-2.0 | GPL-3.0+ with a name clause ("no derivative may use the name or imply association") | see §3.6 |
| macOS arm64 size (gz, unpacked) | 20.8 MB, 57 MB | 19.7 MB zip, ~50 MB (**estimate**) | 29 MB gz, ~80 MB (**estimate**) | |
| Release cadence | stable tag every few weeks (1.19.32 on 2026-09-30) | v26.x tags ~every 2-4 weeks, all marked prerelease on GitHub; stable v26.3.27 | 1.14.3 stable, 1.15.0-alpha weekly | |

### Gaps of mihomo vs the others, ranked by practical value for the StorkVPN-type panel
1. **REALITY `minClientVer`** (version byte 1.8.2 fixed in code): cannot be changed by config. Hosts that raise
   `minClientVer` (an anti-scanner/anti-old-client measure) are unreachable. Fix = Xray.
2. **Finalmask / fragment / noise / header-custom / XHTTP-over-QUIC masks** and every new xHTTP knob.
   Fix = Xray. These are the DPI-bypass tools that change fastest in the RU/BY censorship arms race.
3. **NaiveProxy** (sing-box only), **sing-box-only protocol quirks** (v2ray-QUIC, Tor). Low priority.
4. In the other direction, mihomo covers what Xray lacks: TUIC, AnyTLS, Mieru, ShadowTLS, SSH, Snell, AmneziaWG, OpenVPN.
   **sing-box adds almost nothing on top of mihomo except Naive**; no xHTTP, no finalmask. It is the weakest candidate.
5. Our own gap, independent of the core: `PROXY_TYPES` in `Helper/ks` does not list protocols mihomo 1.19.32 already
   has (masque, trusttunnel, sudoku, shadowquic, openvpn, ...). Adding them is a cheap win (§5, phase 0).

## 3. Adding alternative cores

### 3.1 Two ways to add a core

**A. Sidecar behind mihomo ("hub and spoke").** mihomo stays the only core with the TUN, DNS, rules, groups,
stats, kill-switch integration. For a server that needs Xray, the helper starts an Xray process (second
LaunchDaemon, gid `_ksvpn`, own signed identifier) with one outbound, listening on `127.0.0.1:<port>` (or a unix socket)
as SOCKS5; the profile gets `{type: socks5, server: 127.0.0.1, port: N, udp: true}` under the server's name.
- pf: Xray's own sockets carry group `_ksvpn`, so they pass to the pinned server IP exactly like mihomo's.
  Its dial goes out the physical interface because server IPs are already in `route-exclude-address`.
  Loop risk is nil as long as the helper adds the Xray server IP to `servers` and the TUN exclusions (same code path).
- Failover/url-test/select/delay/traffic/direct_sig: unchanged, the server is just a SOCKS proxy to mihomo.
  Per-app split tunnel and Russian-sites-direct unchanged (rules are mihomo's).
- Costs: one extra local hop (loopback, small CPU), UDP through SOCKS5 UDP-associate (Xray supports it; QUIC/
  Hysteria2-over-Xray is rarely needed), per-connection stats show "socks5 -> 127.0.0.1" (fine), Xray's own
  traffic counters needed for the sidecar's byte totals only if we want them.
- Security: the helper must validate Xray outbound JSON like it validates mihomo proxies (whitelist protocol,
  no `sendThrough`, no `sockopt.interface/mark/dialerProxy` pointing outside, no `freedom`/`blackhole` outbounds,
  no inbound other than the generated loopback one, no `api`, `stats`, `dns` of the subscription). This is the same
  "subscription cannot open ports" rule as today.

**B. Full backend swap ("core owns the TUN").** Run Xray-TUN or sing-box-TUN instead of mihomo for the whole
session. Needs a second config generator (`core_generate` equivalent), a second `direct_sig`, second stats adapter,
second DNS design (Xray does not set macOS DNS; sing-box does), re-implemented split tunnel and failover.
Only worth it if a user wants a core globally (e.g. "Xray everywhere"), which is rare.

**Recommendation: A first, B only as a later, optional step (and only for sing-box if at all).**

### 3.2 Xray-core specifics
- macOS: official `Xray-macos-arm64-v8a.zip` (19.7 MB), plus amd64. Plain Go binary, not signed/notarized by upstream:
  we re-sign (Developer ID, hardened runtime, timestamp) as we already do for mihomo.
- TUN exists for darwin but the README says macOS system DNS is not configured from `dns`; we do not need it under model A.
- Config: native JSON; Remnawave's Xray-json template (with `injectHosts`) is already the panel's own product, so
  per-host outbounds can be taken verbatim from the panel's Xray-json response. Finalmask options also travel in
  share links as `fm`.
- Stats: gRPC StatsService on an `api` inbound (can be a loopback port or unix socket **(verify unix)**);
  gives counters, not a connection list. Under A we do not need it.
- License MPL-2.0: file-level copyleft; shipping the unmodified binary in a closed app is fine (give notice and a source link).
- Release risk: a new tag every 2-4 weeks, all flagged prerelease, config keys move (`udpHop` -> `udphop` mask,
  fragment `length` -> `lengths` array, QUIC params moved into finalmask). Pin a version and test configs against it;
  never auto-update the core independently of the helper templates.

### 3.3 sing-box specifics
- Official darwin arm64/amd64 tarballs (29 MB gz); also .pkg/Apple builds. Mature TUN on macOS and DNS rules; has
  `process_path`, Clash API for stats (TCP + secret; unix socket **verify**).
- Adds: NaiveProxy (only core), OpenConnect, Tor. Lacks xHTTP and finalmask. Our existing mihomo already covers
  its other protocols. Subscription template exists (Remnawave "Sing-box").
- License GPL-3.0+ with a trademark-ish name clause. Bundling an unmodified GPL binary and running it as a separate
  process is "aggregation", allowed, but we must offer the corresponding source (a link/pin to the exact tag) and keep
  the license text. We already do this for mihomo (also GPL-3.0) - confirm the About screen/NOTICE has it. **If the app
  is ever to link GPL code in-process, it would have to be GPL itself; do not.**
- Recommendation: **do not bundle by default.** Reconsider only for Naive demand.

### 3.4 AmneziaWG / wireguard-go standalone
mihomo 1.19.32 already has WireGuard + AmneziaWG v1/1.5/2 options (`metacubex/amneziawg-go`, MIT). Nothing to add
unless its AWG implementation lags (then amneziawg-go as a sidecar over a SOCKS wrapper is awkward: it is a TUN
tool, not a proxy). Skip.

### 3.5 Signing, notarization, update strategy
- Each extra binary: ~50 MB (Xray), signed with its own identifier (`com.lesha19.KillSwitch.core.xray`), hardened
  runtime, secure timestamp, no extra entitlements; inside `Resources/Helper`, then notarized with the app.
  App size grows ~20 MB in the DMG (compressed).
- `TrustedCode.Program` gets `.xray`; content filter requirement mirrors `.core` with the new identifier.
- Pin versions + sha256 in a `fetch-xray.sh` like `fetch-mihomo.sh`; `install.sh` `core_update` extends to a second binary,
  second plist (`local.killswitch.core.xray`), same "restart only if changed" rule. The sudoers list does not grow
  if the sidecar is started and stopped by `ks core on|off|refresh` (no new verbs for the user).
- Updating cores: only through app updates (Sparkle). No in-place binary download by the helper: a root process that
  downloads and execs code is a larger attack surface than the whole feature is worth.

### 3.6 Licensing summary
| Core | License | Bundling in a closed or open app (separate process, unmodified) |
|---|---|---|
| mihomo | GPL-3.0 | OK as aggregation; ship license + source offer (tag URL). Already the case. |
| Xray-core | MPL-2.0 | OK; notice + source link; modifications to Xray files would have to be published. |
| sing-box | GPL-3.0+ with name clause | OK as aggregation; do not use the name for our product; source offer. |
Not legal advice; confirm with the repo's licensing choice (KillSwitch's own licence was not found in the repo root).

## 4. Recommended architecture

### 4.1 Core abstraction (`CoreBackend`)
Two layers, because the app and the helper are different worlds:

- **App (Swift)** talks to `HelperClient`/XPC with verbs already abstracted from mihomo (`state`, `proxies`,
  `select`, `delay`, `traffic`, `refresh`, `import`). Add a Swift protocol only for what differs per *format*:
```swift
protocol CoreBackend {
    var id: CoreID { get }                         // .mihomo, .xray
    var subscriptionUserAgent: String { get }      // which template Remnawave must return
    func parse(subscription: Data) throws -> [ServerEntry]   // -> neutral ServerEntry
    func canHandle(_ server: ServerEntry) -> Capability       // .native / .needsAlternate / .unsupported
}
struct ServerEntry { name, host, port, protocol, transport, security, params; sourceCoreHint; raw: ProfileFragment }
```
  `ProfileConverter` today returns a mihomo `Profile`; it becomes `MihomoBackend.parse`. A new `XrayBackend.parse`
  reads Xray-json (Remnawave's own template) and yields entries whose `raw` is the Xray outbound.
- **Helper (bash/perl/plutil, root)**: the profile JSON gains an optional per-proxy key `x-ks-core`:
  `{"<proxy>": {"core":"xray","outbound":{...}}}` next to `x-ks-overrides`. `core_generate` (a) validates it with a
  strict whitelist, (b) emits a mihomo `socks5` proxy named `<proxy>` pointing to the sidecar's loopback port,
  (c) writes `xray.json` (inbound = the one loopback SOCKS, outbound = the validated one, no api/dns/routing),
  (d) adds the outbound's server IP to `servers`/`route-exclude-address`. A second plist runs Xray with gid `_ksvpn`.
  `ks core on|off|state` start/stop both; the app sees one server list, as today.
- Rule of thumb: **mihomo is the control plane; other cores are dial-out engines.** One DNS, one TUN, one rule set,
  one kill switch.

### 4.2 Per-server automatic core choice
1. Fetch the subscription twice (same URL, two UAs): the mihomo YAML (today) and Xray-json (one more request per refresh,
   HWID header identical). Match servers by name or by (host, port, uuid); Remnawave generates both from the same host rows.
2. Choose per server: if the Xray-json entry has `finalmask`, a REALITY `minClientVer`-incompatible host (detectable:
   server rejects the handshake, or panel marks it), or an xHTTP field mihomo's `xhttp-opts` lacks -> `xray`;
   else `mihomo` (default, cheapest, nothing extra running). If the Xray-json is unavailable, everything stays on mihomo.
3. Failure learning: if a mihomo server fails the delay test but its Xray twin works (or the reverse), remember the
   choice per server in UserDefaults (like `Transport` overrides) and surface it as a badge.
4. Sidecar starts only when at least one server uses it (zero cost for users who never need it).

### 4.3 UI
- Settings -> Дополнительно: "Движок: Авто (рекомендуется) / только mihomo / только Xray для всех серверов, где можно".
- Server row: small tag "Xray" where chosen; per-server override menu next to the existing «Как в подписке» transport menu.
- Diagnostics copy (`DiagnosticsCopy`) prints both core versions.

### 4.4 Risks
| Risk | Mitigation |
|---|---|
| Doubled attack surface: a second root-launched parser of subscription content | Strict whitelist for the Xray outbound, no inbound from the subscription, loopback/unix socket only, port random per boot, authentication on the SOCKS (`user:pass` generated by helper) so other local users cannot use the sidecar. |
| Loopback SOCKS reachable by other local processes | Unix socket (`ctl/xray.sock`, root-only dir) if mihomo accepts a socks5 over a unix path **(verify; mihomo `socks5` outbound takes host:port; may need a loopback port + SOCKS auth + pf `user/group` rule)**. Fallback: random loopback port + auth. |
| Xray config churn (monthly breaking changes, prerelease tags) | Pin; run `xray run -test -c` in `core_generate` as `mihomo -t` is used now; keep a fixtures test per pinned version; update with the app only. |
| Two-process state (one dies) | Same `KeepAlive` launchd job; `ks core state` reports sidecar health; mihomo marks the server dead, failover moves on. |
| Fingerprint/behavioural mismatch (Xray vs mihomo uTLS) | Not a regression: used only where mihomo cannot connect. |
| Per-app split tunnel / process rules not available in a pure-Xray model | Avoided by model A. |
| Reality version leak: a custom mihomo patch is the alternative to Xray for `minClientVer` | Cheaper but means forking/patching a GPL core and tracking upstream: rejected (could be raised upstream as an issue/PR for configurable version). |
| macOS DNS under Xray-TUN | Avoided by A. |
| Binary size/notarization time | +20 MB DMG; acceptable. |
| License notices | Add NOTICE/About entries for Xray (MPL-2.0) and keep mihomo's GPL text; check the app's own licence stance. |

## 5. Phases and effort (one developer + agent; "d" = working days, includes tests and a clean-Mac check)

| Phase | Content | Effort |
|---|---|---|
| 0. Mihomo coverage (no new core) | Extend `PROXY_TYPES` and per-type validation in `Helper/ks` for masque, trusttunnel, sudoku, shadowquic, openvpn, etc. (only those that have a stable meaning and a `server` field); extend `ProxyLink` (hysteria2/tuic/anytls/ss-2022/shadowtls links); fixtures in `Helper/tests`; check mihomo build tags of the *release* binary (`mihomo -v`, a config per type with `-t`); document the gap list. Optionally upstream issue/PR for configurable REALITY version. | 2-4 d |
| 1. Sidecar plumbing | `fetch-xray.sh` + sign (`sign-core.sh`, new identifier) + `TrustedCode.Program.xray`; second plist; `install.sh` second-binary update; `ks` verbs start/stop/state for sidecar; `xray run -test`; hardcoded single-outbound template (hand-written JSON for one test host); pf/leak tests with the sidecar (`Helper/tests/rules.sh`, a leak test in `LeakTester`). Needs an Opus/clean-Mac pass. | 5-7 d |
| 2. Xray-json ingestion + whitelist | `XrayBackend.parse` for Xray-json (Remnawave template, `injectHosts`), neutral `ServerEntry`, `x-ks-core` in the profile, helper validation (protocols vless/vmess/trojan/ss/hysteria2/wireguard; transports tcp/ws/grpc/httpupgrade/xhttp; security tls/reality; finalmask masks whitelist), tests, a fuzz-ish test of malformed outbounds. | 6-9 d |
| 3. Auto choice + UI | Dual fetch/refresh, matching, `canHandle`, per-server override, Settings strings (ru), diagnostics, ADR 0013 (this design), user-facing doc. | 4-6 d |
| 4. Hardening / soak | Failover across cores, update path (`install.sh --upgrade`), Sparkle update test with sidecar running, uninstall cleanup, Mac sleep/wake, 1-week soak on the Air. | 3-5 d |
| 5. (optional) sing-box backend | Only if Naive or a sing-box-only protocol is requested: same sidecar pattern with sing-box `naive` outbound + mixed inbound; license notice. | 4-6 d |
| 6. (optional, not recommended) full core swap | Second config generator + `direct_sig` + DNS + split tunnel for Xray-TUN or sing-box-TUN. | 15-25 d |
Total for the recommended scope (0-4): about 20-31 working days. Phase 0 alone gives the largest protocol gain per effort.

## 6. What the owner gains (protocols/features)
- Phase 0: every protocol mihomo 1.19.32 already has but the whitelist blocks (masque, trusttunnel, sudoku,
  shadowquic, openvpn ...), and link import for modern links.
- Phase 1-3: Finalmask (fragment/noise/header-custom/udphop), newest xHTTP knobs, REALITY with `minClientVer` on the server,
  Xray-native Hysteria2/WireGuard FullCone, with zero change to TUN/DNS/kill switch/split tunnel.
- Phase 5: NaiveProxy.
- Not worth adding: Juicity (dead), standalone AmneziaWG (mihomo has it), a second full TUN core.

## Close-out: phase 0 done (2026-10-10, #9, branch `cores-phase0`)
- Verified on the pinned binary: `mihomo -v` = v1.19.32 darwin arm64, build tags `with_gvisor` only.
  Types from `adapter/parser.go` of the tag, each tried with `mihomo -t`: ss, ssr, socks5, http, vmess,
  vless, snell, trojan, hysteria, hysteria2, wireguard, tuic, shadowquic, gost-relay, ssh, mieru, anytls,
  sudoku, masque, trusttunnel, openvpn, tailscale, zerotier, easytier. **Tailscale and ZeroTier are in the
  release binary** (the "build tag stubs" guess above was wrong), EasyTier too.
- Not in this build: naive, juicity, tor; JLS and Restls are not types but shadowsocks plugins (`plugin: jls`,
  `plugin: restls`) and `jls-opts`/`restls-opts` of vless/vmess/trojan/anytls; TLS-mirror is `tlsmirror-opts`
  of vmess.
- `PROXY_TYPES` now also has masque, trusttunnel, sudoku, shadowquic, openvpn. Left out on purpose:
  tailscale, zerotier, easytier (own control plane and peers, pf would have to open them), gost-relay
  (no demand yet). Each type keeps only its mihomo keys; file-path certificates, `dialer-proxy` outside
  the profile, hysteria2 realms are refused (ADR 0014).
- Link import added: vmess://, anytls://, socks5://, http(s)://, xHTTP `extra` incl. downloadSettings,
  ss v2ray-plugin/shadow-tls, AmneziaWG fields in wireguard:// links.
- Still open from this document: REALITY `minClientVer` and finalmask (phase 1+, Xray sidecar); MASQUE/
  TrustTunnel/Sudoku/ShadowQUIC/OpenVPN were checked with `mihomo -t` only, not against live servers.

## Sources
- mihomo: https://github.com/MetaCubeX/mihomo (v1.19.32 trees: adapter/outbound, transport, component/tls/reality.go, transport/xhttp/config.go, adapter/outbound/{vless,wireguard,hysteria2,tuic}.go); docs https://wiki.metacubex.one/en/config/proxies/ ; https://core-tutorial.argsment.com/mihomo/transport ; https://core-tutorial.argsment.com/mihomo/vless ; releases https://github.com/MetaCubeX/mihomo/releases
- Xray-core: https://github.com/XTLS/Xray-core (proxy/tun/README.md, tun_darwin.go, transport/internet/{splithttp,finalmask}, infra/conf/transport_internet.go); release v26.3.27 https://github.com/XTLS/Xray-core/releases/tag/v26.3.27 ; releases https://github.com/XTLS/Xray-core/releases ; XHTTP: https://github.com/XTLS/Xray-core/discussions/4113 ; https://github.com/XTLS/Xray-core/discussions/6042
- sing-box: https://github.com/SagerNet/sing-box (protocol/, transport/, common/tls/reality_client.go, docs/changelog.md, docs/configuration/experimental/clash-api.md); release https://github.com/SagerNet/sing-box/releases/tag/v1.14.3
- amneziawg-go https://github.com/amnezia-vpn/amneziawg-go ; wireguard-go https://github.com/WireGuard/wireguard-go ; Juicity https://github.com/juicity/juicity
- Remnawave templates https://docs.rw/learn-en/templates ; https://docs.rw/learn/xray-json-advanced
- Local: ~/KillSwitch/docs/adr/0001, 0003, 0005, 0007, 0009, 0010, 0012; Helper/ks (core_generate, PROXY_TYPES, direct_sig); Helper/install.sh (core_update); Helper/fetch-mihomo.sh; Filter/TrustedCode.swift; App/Core/ProfileConverter.swift; App/Core/SubscriptionHeaders.swift; scripts/release.sh.
