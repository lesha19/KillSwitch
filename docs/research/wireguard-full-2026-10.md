# WireGuard at Mullvad/IVPN level: client + own-server research (2026-10-10)

Status: research for issue #21 (builds on `mullvad-ivpn-gap-2026-10.md`, `multi-core-2026-10.md`, core selector #31).
Nothing implemented, nothing in the repo changed except this file.

Premise that changes the earlier verdict: the owner runs his own VPS (Ubuntu 24.04, Lithuania, Remnawave node with
Xray on 443/2083). `mullvad-ivpn-gap` marked DAITA, PQ and WG obfuscation as "N/A" because the server side is fixed by
a subscription. With our own server they become "client + server pair" tasks, so most of them are possible.

Method: shallow clones of the upstream repos read on 2026-10-10 (commits in "Sources"). Everything below is from source
code unless marked **(verify)** = not run on a real binary / not confirmed. Effort: S < 1 day, M = days, L = 1+ week.

## 1. Key facts found in the source (corrections to common beliefs)

1. **Mullvad no longer uses wireguard-go.** Since 2025/26 every desktop platform uses **GotaTun**
   (`mullvad/gotatun`, Rust, fork of Cloudflare BoringTun). CHANGELOG 2026.3-beta1: "GotaTun is now used ... on all
   desktop platforms, not just macOS. It replaces wireguard-go". GotaTun license is **MPL-2.0** (since 2026-03-05, older
   contributions BSD-3), NOT GPL. `gotatun-cli` is a stand-alone wireguard-go-style daemon (utun on macOS, UAPI socket,
   works with `wg` and `wg-quick`). aarch64-apple-darwin is a tested target; x86_64-apple-darwin is not in the list.
2. **DAITA is built into GotaTun** behind `--features daita-uapi` (non-standard UAPI keys `daita_enable`,
   `daita_machine`, `daita_max_decoy_frac`, `daita_max_delay_frac`, ...). Machines are `maybenot` (MIT OR Apache-2.0)
   and `maybenot-machines`/`maybenot-gen` are public, with client/server machine pairs (RegulaTor, FRONT, Interspace,
   Tamaraw, Scrambler, BreakPad). So a DAITA server can be GotaTun on our VPS. Mullvad's own relay machines are not public.
3. **Mullvad PQ today = ML-KEM-1024 + HQC-256** (Classic McEliece was dropped for HQC; changelog line ~568). PSK = XOR of
   the two KEM secrets. Exchange runs **inside** an already-up WG tunnel (gRPC on the relay's tunnel gateway IP, port 1337),
   then the client swaps to a new "ephemeral" WG key + that PSK. Current app does it through a temporary userspace
   GotaTun device + smoltcp netstack, so it needs no tun, routes or firewall exceptions beyond the relay endpoint.
   The **server side is closed**; only the proto (`ephemeralpeer.proto`) and clients are public
   (`mullvad/wgephemeralpeer`, Go, GPL-3.0, plus the Rust crate in the app).
4. **IVPN PQ differs**: Kyber1024 + Classic-McEliece-348864 via liboqs (`kem-helper`, C), public keys sent to IVPN's
   HTTPS API together with the WG key (not through the tunnel), PSK = SHA-256(secret1 || secret2). Server closed.
5. **IVPN V2Ray = V2Ray v5.12 sidecar** (local `dokodemo-door` UDP 127.0.0.1:16661 -> VMess outbound over QUIC+TLS with
   `srtp` header, or TCP with fake HTTP header) in front of WG; each IVPN host has a separate V2Ray IP.
   **obfs4 in IVPN is OpenVPN-only** (changelog 3.x), not WireGuard. IVPN multihop = entry host gets a per-exit
   `multihop_port` (server-side feature), unlike Mullvad where the client nests two WG devices.
6. **mihomo (Meta branch, 2026-09-30) already ships WireGuard + AmneziaWG up to "version 3"** options
   (`amnezia-wg-option`: jc/jmin/jmax, s1-s4, h1-h4 as ranges, i1-i5, header-protection-key, content-padding-addition,
   rekey/keepalive timings, random-trailers...). WG runs in mihomo's own userspace netstack: **no extra utun, no pf change**.
   Outbounds accept `dialer-proxy`, so WG UDP can ride inside any other proxy (SS-UDP, hy2, VLESS XUDP...).
   mihomo has no PQ exchange, no DAITA, no LWO. Its `masque` outbound is Cloudflare-WARP-style (keys, `uri`), not a generic
   CONNECT-UDP client, so it is NOT the analogue of Mullvad's QUIC obfuscation.
7. **Xray v26.10.10 has a WireGuard inbound AND outbound, and both dial/listen through `finalmask`** (UDP masks:
   salamander, mkcp header, noise, header-custom, xdns, xicmp, udphop ...). So "WG + Hysteria-style salamander" or
   "WG + noise packets" is a pure Xray client+server pair. Xray has no QUIC transport any more (V2Ray-QUIC is gone),
   so IVPN's exact V2Ray-QUIC profile cannot be reproduced; the VLESS/xHTTP/Reality equivalent can.
8. **Mullvad obfuscators** (all in `tunnel-obfuscation`, GPL-3.0-or-later, order of auto-retry in `docs/relay-selector.md`):
   LWO (3rd attempt), Shadowsocks, QUIC (port 443), UDP2TCP (ports 80/443/5001). Shadowsocks is plain AES-256-GCM with
   password `mullvad` to an ordinary ss UDP relay; UDP2TCP is a separate MIT/Apache repo with the **server** binary
   (`tcp2udp`) included.
9. **Static PSK already gives PQ resistance for the handshake** (WG whitepaper: PSK mixed into key derivation). A random
   32-byte PSK shared out-of-band with our own server is "quantum-resistant" against harvest-now-decrypt-later. KEMs only add
   automatic distribution + rotation (forward secrecy of the PSK itself). Cheapest honest PQ for a one-user server.

## 2. Feature table

"Server part available?" = open-source component we can deploy on the VPS. "Can we" = in our root-daemon + pf model.
Engine key: **A** = inside mihomo (userspace, no pf change). **B** = GotaTun sidecar with its own utun (new). **X** = Xray sidecar (#10).

| Feature | Mullvad | IVPN | How it works | Client part | Server part available? | Can we do it | Effort |
|---|---|---|---|---|---|---|---|
| Plain WG from subscription / `.conf` | yes | yes | Curve25519 + ChaCha20-Poly1305 UDP tunnel | mihomo `wireguard` outbound (A) | kernel WG / wireguard-go (MIT) | Yes, already in `PROXY_TYPES`; add `.conf` import | S |
| AmneziaWG v1 / v1.5 / v2(=3) junk, paddings, headers, I1-I5, header protection | no | no | Random junk packets before handshake (Jc/Jmin/Jmax), padding S1-S4, custom message-type values H1-H4 (ranges in v2+), CPS signature packets I1-I5 imitating QUIC/DNS/SIP; v3 adds header-protection key, content padding, timers | mihomo `amnezia-wg-option` (A), `metacubex/amneziawg-go` (MIT); standalone `amneziawg-go` MIT | `amneziawg-go` (MIT), kernel module `amneziawg-linux-kernel-module` (GPL-2.0), `amneziawg-tools` (GPL-2.0); Ubuntu PPA exists **(verify)** | Yes, fully. Params H*, S*, header key must match both ends; J*, I*, content padding are client-only | S (client), M (own AWG server) |
| Static PSK (PQ-by-PSK) | n/a | n/a | 32-byte secret mixed into every handshake | mihomo `pre-shared-key` (A) | `wg set ... preshared-key` | Yes. Exactly what #21 asks as "WireGuard PSK" | S |
| Quantum-resistant tunnel, Mullvad variant (ML-KEM-1024 + HQC-256 ephemeral peer) | default on | no | Over a live tunnel send KEM public keys + new ephemeral WG pubkey; server returns ciphertexts; PSK = XOR secrets; client switches to ephemeral key+PSK | Needs control of the WG device: GotaTun UAPI (B). Rust crate `talpid-tunnel-config-client` (GPL-3) or Go `wgephemeralpeer` (GPL-3, uses circl: ML-KEM-1024, Kyber1024, McEliece460896; **HQC not in it**) | **Closed on Mullvad side.** We would write our own ~300-line service (Go: `crypto/mlkem` is in stdlib; HQC via liboqs/PQClean cgo) on the tunnel gateway IP; proto is public so we may reuse it | Partially: crypto + protocol yes, but only against OUR server, never against Mullvad relays (no account, closed server). Not possible inside mihomo (no PSK hot update) | M-L |
| Quantum-resistant, IVPN variant (Kyber1024 + McEliece348864) | no | yes | Public keys go to the IVPN HTTPS API with the WG key; PSK = SHA-256(s1 ‖ s2) | liboqs `kem-helper` (C, GPL-3) | Closed (IVPN API) | No as such: needs IVPN API. Our own design should copy Mullvad's in-tunnel scheme or use Rosenpass | n/a |
| **Rosenpass** (our best PQ pair) | no | no | Separate daemon pair does a PQ handshake (Classic McEliece 460896 static + Kyber-512 ephemeral, round-3) over its own UDP port and writes a fresh PSK into WG every ~2 min | `rosenpass` (Rust, MIT/Apache, release `aarch64-darwin` 0.2.3) + GotaTun/wireguard-go with `wg` (B) | Same `rosenpass` on the VPS (x86_64-linux release) | Yes with engine B: runs as root daemon, UDP port must be allowed in pf for group `_ksvpn` **(verify macOS broker/`wg` path)**. Not with engine A | M |
| PSK rotation | every new tunnel (ephemeral) | at WG key rotation | New PSK per KEM run | B + Rosenpass (2 min) or own service per reconnect | as above | With B yes; with A only by regenerating config and restarting the outbound (reconnect gap) | M |
| DAITA v1 (fixed machines) | legacy (Linux/macOS 2024) | no | maybenot state machines add decoy packets and delays, fixed-size data packets | in GotaTun now | relay support | Superseded by v2 | - |
| DAITA v2 (relay-supplied machines, constant packet size, padding/delay fractions) | yes, auto multihop to capable relays | no | Both ends run machines; decoy = WG data packet with plaintext marker 0xff; client asks via `DaitaRequestV2`, relay returns machine strings and `max_padding_frac`/`max_blocking_frac` | GotaTun built `--features daita-uapi` (B); set machines via UAPI | **Yes, our own:** GotaTun (MPL) on VPS with `daita-uapi`, server machines from `maybenot-machines`/`maybenot-gen` (MIT/Apache). Needs a custom UAPI writer, not stock `wg` | Technically yes, B only, pair of GotaTun both ends. Mullvad's tuned machines are private, so protection is research-grade (FRONT/Interspace/RegulaTor). Costs bandwidth. Not with A or Xray | L |
| Multihop (two WG hops) | client nests entry+exit device | server-side `multihop_port` on entry | Exit's UDP rides inside the entry tunnel | A: second `wireguard` outbound with `dialer-proxy: wg-entry` **(verify UDP-over-WG dialer)**; our "Double VPN" already does it for proxies | Two WG servers (the only VPS = one hop; second needs another host) | Yes in A. With only one VPS: entry = VPS, exit = another provider | S-M |
| UDP-over-TCP | yes (udp2tcp) | no | 2-byte length framing of datagrams in a TCP stream (ports 80/443/5001) | A: mihomo SS `udp-over-tcp` or VLESS/Trojan XUDP via `dialer-proxy`. B: Mullvad `udp2tcp` binary (MIT/Apache) as local obfuscator | `tcp2udp` (MIT/Apache, systemd unit included) | Yes, fully (A with mihomo transports; B with `udp-over-tcp`) | S (A), M (B) |
| Shadowsocks obfuscation | yes | no | WG datagrams wrapped in SS-AEAD UDP (AES-256-GCM) to an SS server that relays to the WG port | A: `dialer-proxy` -> mihomo `ss` with `udp: true`. B: mihomo `tunnels:` listener 127.0.0.1:N -> ss proxy | `shadowsocks-rust` (MIT) or Xray `shadowsocks_2022` inbound on VPS | Yes, fully | S |
| QUIC / MASQUE obfuscation | yes (since 2025.9, port 443) | no | HTTP/3 CONNECT-UDP with HTTP datagrams (`mullvad-masque-proxy`, quinn+h3) to a relay that forwards to WG, Bearer token | Mullvad crate (GPL-3). Free analogue: WG over Hysteria2 (mihomo `hysteria2` via `dialer-proxy`), or Xray `masque`/`hysteria` | `masque-server` example is in the same GPL-3 repo; or Hysteria2 / Xray hysteria inbound | Analogue yes (hy2 is QUIC and on mihomo today). Exact Mullvad MASQUE only as a separate GPL process | S (hy2 analogue), M (Mullvad masque proxy) |
| LWO v1/v2 (lightweight WG obfuscation) | yes (3rd auto attempt, port setting) | no | v1: XOR the first 16/148/92/64 header bytes with the server pubkey (per-direction key), random byte 1 with MSB set. v2: protected 16-byte area + marker bits + random handshake padding up to 256 B **and custom WG timers on both ends** | `tunnel-obfuscation::lwo` (GPL-3) in GotaTun transport hook; reimplementing v1 is trivial XOR | **Closed on relays.** v1 server = ~100-line UDP relay we write; v2 needs a server WG with the patched timers = GotaTun fork/patch | Partially: own protocol "LWO-like" yes (B). Compatibility with Mullvad not needed. AmneziaWG already gives the same effect inside mihomo, so prefer AWG | M (v1-like), L (v2) |
| IVPN V2Ray (VMess/VLESS over QUIC/TCP wrapping WG) | no | yes (3.12+) | Local UDP inbound -> V2Ray outbound -> server V2Ray -> WG | A: WG outbound with `dialer-proxy: <VLESS Reality / xHTTP proxy>` = exactly the same idea, UDP via XUDP. X: Xray WG outbound + sidecar | Our existing Remnawave Xray node: freedom outbound to WG UDP (local or public IP) **(verify routing rules allow it)** | Yes, fully, with the technology we already have (better than V2Ray-QUIC, which no longer exists in Xray) | S-M |
| obfs4 | no | OpenVPN only | Tor pluggable transport | n/a for WG | n/a | Skip (no WG use; Reality/AWG/hy2 cover the job) | - |
| Xray finalmask on WG (salamander, noise, header-custom, mkcp, xdns, xicmp, udphop) | no | no | Xray WG outbound/inbound dial UDP through `FinalMask.DialUDP`/`ListenPacket` | X: Xray sidecar from #10 | Xray WG inbound on the VPS, same masks | Yes after Xray sidecar exists. Server: separate Xray or a WG inbound in the Remnawave config profile **(verify)**. Xray WG server is userspace netstack, slower than kernel WG | M |
| MTU selection | default 1380 + auto-detect on connect (ping probes lower by 20-byte steps, min 1280) | setting | Inner MTU minus obfuscation overhead (SS = salt+addr+tag, QUIC mtu param, LWO 0) | A: `mtu` field; B: set utun MTU, compute overhead | n/a | Yes; reuse #18 MTU field; later probe-based auto MTU | S |
| Port selection | WG port, UDP2TCP ports, SS range | multiple ports | Pick UDP port (51820/53/123/443) to dodge port rules | profile field | open ports on VPS firewall | Yes (S); pick 443/UDP, 53, or a port-hopping set | S |
| DNS over WG | relay-internal resolver 10.64.0.1 (+ blockers) | internal DNS / custom DoH | Resolver reached inside the tunnel | A: `dns` + `remote-dns-resolve`; fits `KS-DNS` group; B: DNS to gateway through mihomo | `unbound`/`dnsmasq` on VPS bound to the WG address | Yes | S |
| Port forwarding, accounts, device keys | yes | yes | provider features | - | - | N/A (own server: just add peers) | - |

## 3. What cannot be done, and why

- **Mullvad PQ/DAITA against Mullvad or IVPN relays**: needs an account and closed server components. Out of scope; KillSwitch is not a provider client.
- **Exact IVPN KEM protocol** (needs IVPN API) and **IVPN V2Ray-QUIC profile** (Xray dropped QUIC transport).
- **PQ rotation and DAITA inside mihomo**: wireguard-go in mihomo has no external control channel. They need engine B.
- **Mullvad LWO v2 wire compatibility**: closed relay side, would need Mullvad's patched timers; we can only build our own variant.
- **WireGuardKit / `wireguard-apple`** (MIT): requires a NetworkExtension packet-tunnel provider with its own routes; incompatible with root daemon + pf + mihomo TUN. Do not use.

## 4. Licensing

| Component | License | Use |
|---|---|---|
| Mullvad app crates (talpid-*, tunnel-obfuscation, masque-proxy, wgephemeralpeer) | GPL-3.0(-or-later) | Only as **separate processes** with a source offer (as mihomo today), or read for protocol and re-implement from the public proto. Copying code into the Swift app would force GPL-3 on KillSwitch (repo has no LICENSE file; decide first). |
| GotaTun | MPL-2.0 | Bundle unmodified binary or build with our patches (publish changed MPL files). Fine for closed apps. |
| maybenot, udp-over-tcp, Rosenpass, shadowsocks-rust, wireguard-go, amneziawg-go, wireguard-apple | MIT / MIT-Apache | Free to bundle, keep notices. |
| Xray-core | MPL-2.0 | as in multi-core doc |
| amneziawg tools / kernel module | GPL-2.0 | Server only (not shipped to users) |
| mihomo | GPL-3.0 | already shipped separately |

## 5. Recommended architecture

**Principle (same as multi-core doc): mihomo stays the control plane (TUN, DNS, rules, groups, stats, split tunnel);
WireGuard engines are dial-out engines.** Two engines, chosen per server:

**Engine A: mihomo WireGuard outbound (default, phase 1).** Covers plain WG, AmneziaWG v1-3, static PSK, multihop,
DNS, MTU, and every "obfuscation by wrapping" through `dialer-proxy`: WG-over-VLESS/Reality/xHTTP (= IVPN V2Ray),
WG-over-Shadowsocks (= Mullvad SS), WG-over-SS-UoT or VLESS (= UDP2TCP), WG-over-Hysteria2 (= QUIC-like).
No pf change: the WG UDP socket belongs to mihomo (gid `_ksvpn`); the first hop's server IP is already pinned into `servers`
and `route-exclude-address`. `ks core import` whitelist: add `wireguard` options (already type-listed) with validation of
`dialer-proxy` target (must be a proxy from the same profile, never DIRECT), `allowed-ips`, `peers`, AWG fields.

**Engine B: `ks-wg` = GotaTun sidecar (phase 3, only for PQ-rotation / DAITA / Rosenpass).**
- Binary: `gotatun-cli` built by us (`--features daita-uapi`), pinned + sha256, signed as `com.lesha19.KillSwitch.core.wg`,
  new `TrustedCode.Program` case, LaunchDaemon `local.killswitch.wg`, run with gid `_ksvpn` and `--disable-drop-privileges`
  (so the pf group rule matches its UDP socket; stock CLI drops to the saved uid).
- Control: UAPI socket in the root-only `ctl/` dir (`wg-quick`-style config written by `ks wg import`); helper does PQ:
  Rosenpass daemon, or our own ephemeral-peer client talking to a tiny service on the VPS.
- Plug into mihomo: GotaTun's utun is a separate interface; mihomo gets a helper-generated `direct` proxy
  `wg:<name>` with `interface-name: utunN` (IP_BOUND_IF) **(verify binding to utun from the gvisor TUN without loops)**.
  Rules, DNS, split-tunnel, failover groups stay unchanged; `direct_sig` must treat this generated proxy as non-leaking
  (helper-made, not from the subscription).
- Obfuscation for B reuses mihomo, no extra obfuscator binaries: GotaTun endpoint = `127.0.0.1:N`, where a helper-generated
  mihomo `tunnels:` entry forwards UDP to the server through the chosen proxy (ss / hy2 / vless). Loopback is already passed by pf.
  Only exception: LWO-like and DAITA-sensitive timing prefer direct UDP.
- Server (our VPS): kernel `wg` (or GotaTun for DAITA), `rosenpass`, `tcp2udp`/ss/hy2 as needed, one Ansible-like script
  `scripts/wg-server-setup.sh` generating keys, PSK, firewall and a client profile. Never auto-installed by the app.

**Kill switch (pf) interplay.**
- Engine A: nothing new in `rules()`; only the endpoint (or first-hop proxy server) goes into the `servers` file.
- Engine B: `vpn_ifaces()` finds tunnels by an address in `198.18.0.0/16`; a WG utun carries the server-assigned address
  (e.g. 10.x), so the helper must add the utun name it learns from `WG_TUN_NAME_FILE` to a `wg-ifaces` file that `rules()` includes
  in the `pass out quick on { lo0 awdl0 llw0 $vpn }` list and in `tunnel_sig` (the watchdog reads this signature each second).
  Without it the watchdog sees "no tunnel" and blocks.
- Mullvad's own lesson: pf keeps states for approved connections, so on endpoint change or ephemeral swap flush states except
  the new endpoint (`talpid-core/src/firewall/macos.rs`, ~lines 99-200: "ephemeral peer exchange becomes unreliable otherwise").
  Do the same in `ks` when the WG endpoint changes or when switching A<->B.
- PQ negotiation window: Mullvad avoids firewall holes by doing it in a temporary userspace device. For B, run the first
  handshake and Rosenpass/KEM exchange before switching `wg:<name>` on; allow only server UDP for group `_ksvpn`. No new
  user-visible leak.
- Core selector #31: the WG engine is orthogonal to mihomo/Xray/pure-Xray. In "pure Xray" mode only Xray's own WG outbound
  (with finalmask) is available; engine B needs mihomo as shell. Switching engines = "refresh with the kill switch closed".

## 6. Phased plan

| Phase | Content | Needs from server | Effort |
|---|---|---|---|
| 0 | `.conf` + `wg://`/AmneziaWG import into `ProfileConverter`; `ks core import` validation for WG/AWG v1-3, static PSK field, MTU, `dns`; leak-test with WG | WG (+AWG) server on VPS, script `wg-server-setup.sh` | S-M |
| 1 | Obfuscation by wrapping (`dialer-proxy`): WG over VLESS-Reality/xHTTP via existing Remnawave Xray node, over SS, over hy2, over SS-UoT; auto-escalation order modelled on Mullvad (direct -> AWG -> SS -> VLESS/hy2 -> UoT) feeding #20 | freedom outbound / ss / hy2 inbound for UDP to WG port; check Remnawave routing | M |
| 2 | Multihop with a second host (WG-in-WG); UI for ports/MTU; MTU auto-probe | second server | S-M |
| 3 | Engine B `ks-wg` (GotaTun) + pf `wg-ifaces` + `interface-name` bridge; Rosenpass PQ with rotation; ADR on engines and leak tests | `rosenpass` on VPS | L |
| 4 | DAITA: GotaTun `daita-uapi` on VPS, generated maybenot machine pairs, UI toggle + overhead display | GotaTun server | L, optional |
| 5 | Xray WG + finalmask once #10 lands (same server Xray, WG inbound) | Xray WG inbound | M |
| 6 | Own LWO-like (v1) and Mullvad-style ephemeral-peer service (ML-KEM-1024 + HQC) only if Rosenpass is not enough | custom service | M-L, low value |

Deliberately skipped: obfs4, IVPN KEM protocol, WireGuardKit/NetworkExtension, Mullvad MASQUE as a binary (hy2 does the same job).

## 7. Open items to verify before coding

1. mihomo `dialer-proxy` on a `wireguard` outbound with UDP going through a VLESS/SS/hy2 chain, and multihop WG-in-WG, on the pinned 1.19.32 binary (config accepted in source; not run).
2. Release-binary build tags: AmneziaWG "version 3" fields present in 1.19.32 or only in current Meta tip (tip commit 88dcbf7, 2026-09-30).
3. `interface-name` binding of a `direct` outbound to a GotaTun utun while mihomo's TUN holds the default route.
4. GotaTun on x86_64 macOS (not in the tested target list) if Intel Macs matter.
5. Rosenpass on macOS with GotaTun/wireguard-go (PSK broker via `wg` binary), and its UDP port in pf.
6. Remnawave: can a WG inbound or an extra UDP forwarding inbound live in the node's config profile, and what Xray version the node runs (finalmask needs v26.3.27+).
7. Effectiveness of non-Mullvad DAITA machines; measure overhead before offering it.
8. KillSwitch license decision (GPL-3 Mullvad code only as separate processes).

## 8. Sources (read 2026-10-10)

- mullvad/mullvadvpn-app @ 4931987 (2026-10-09): `CHANGELOG.md`, `docs/architecture.md` (PQ, multihop), `docs/relay-selector.md`,
  `talpid-tunnel-config-client/proto/ephemeralpeer.proto` and `src/{lib,ml_kem,hqc,negotiation}.rs`, `talpid-wireguard/src/{ephemeral,lib,mtu_detection}.rs`,
  `tunnel-obfuscation/src/{lwo,shadowsocks,quic,udp2tcp}`, `mullvad-masque-proxy/src/server`, `talpid-core/src/firewall/macos.rs`, license GPL-3.0-or-later.
- mullvad/gotatun (README, UAPI.md, Cargo features, `device/daita`, `gotatun-cli`), MPL-2.0: https://github.com/mullvad/gotatun
- mullvad/wgephemeralpeer (GPL-3.0): https://github.com/mullvad/wgephemeralpeer
- maybenot-io/maybenot @ 539f645 (MIT OR Apache-2.0): https://github.com/maybenot-io/maybenot
- mullvad/udp-over-tcp 0.4.0 (MIT OR Apache-2.0): https://github.com/mullvad/udp-over-tcp
- ivpn/desktop-app @ 1fd0630 (2026-10-06): `daemon/kem/*`, `daemon/v2r/config.go`, `daemon/References/common/etc/servers.json`, `CHANGELOG.md`.
- amnezia-vpn/amneziawg-go @ b5928ef (2026-08-28, MIT): README (junk, S1-S4, H1-H4 ranges, I1-I5, header protection, timings).
- MetaCubeX/mihomo (branch Meta) @ 88dcbf7 (2026-09-30): `adapter/outbound/{wireguard,masque,shadowsocks}.go`, `go.mod`, `listener/tunnel`.
- XTLS/Xray-core @ 701af60 (v26.10.10): `proxy/wireguard/{client,server}.go`, `transport/internet/finalmask/*`, `infra/conf/wireguard.go`.
- rosenpass/rosenpass @ 2026-10-09 (README, `papers/whitepaper.md`, `rosenpass/src/protocol/constants.rs`, release 0.2.3 with aarch64-darwin).
- GitHub license API: WireGuard/wireguard-go MIT, WireGuard/wireguard-apple MIT, mullvad/wireguard-go MIT, shadowsocks-rust MIT, amneziawg-linux-kernel-module and -tools GPL-2.0.
- Local: `Helper/ks` (`vpn_ifaces`, `rules`, `as_core_group`), issues #9, #10, #21, #31.
