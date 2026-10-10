# ADR 0006: telling why nothing works with a pf-limited probe

- Status: accepted (0.10)
- Date: 2026-10-10

## Context

When every server stops answering, the person sees «Защищено» and nothing loads. In Russia there
are three usual reasons that need different actions: no internet at all (router, balance, captive
portal), the mobile «white lists» (only approved Russian sites answer; nothing to do but Wi‑Fi or
wait), and our servers blocked by DPI (another server, refresh, support). The kill switch blocks
everything outside the tunnel, so the app itself cannot look past it.

## Decision

- **`ks probe`** (passwordless in sudoers) prints `link=0|1 ru=0|1 foreign=0|1`: `link` is a
  primary interface; `ru`/`foreign` is a TCP handshake (`curl --connect-timeout 3 -m 4`, no request
  needed — `time_connect` > 0 counts) to `77.88.8.8`/`77.88.8.1` (Yandex DNS, kept open in the
  white lists) and to `1.1.1.1`/`8.8.8.8`, from the physical interface (`--interface`, past the
  TUN), as the core's group `_ksvpn`, first answer wins.
- **pf**: one new line, only while the core's group is not passed broadly (since ADR 0013: while
  `core/egress` is empty; before, without coredirect):
  `pass out quick proto tcp to { 77.88.8.8, 77.88.8.1 } port 443 group _ksvpn`. The foreign
  addresses already pass for the DoH fallback. No process but the helper and the core carries
  `_ksvpn`, and the core never dials these addresses DIRECT unless a profile rule approved by
  the admin says so (same reasoning as the DoH line).
- **The app** (`NetworkCause`) runs the probe at most once a minute, only while no server of the
  profile is alive in the core's health checks or the chosen country is down (ADR 0005), and
  classifies: no link → «Нет подключения к сети»; neither answers → «Интернета нет»; only Russian →
  «Оператор пускает только на российские сайты»; both answer but no server → «Серверы VPN
  недоступны». Banner 2б, right after «Работает другой VPN».

## Consequences

- One Russian address set is hard-coded; if Yandex DNS leaves the white lists or stops listening
  on 443, «white lists» show as «Интернета нет». The addresses are a constant in Helper/ks.
- A helper older than 0.10 has no `ks probe`: the banner simply does not appear.
- The macOS filter (NEFilter) does not stand in the way: the app probes only while the core runs,
  and with a tunnel up the filter allows every flow (pf does the filtering).
- A handshake is a coarse signal: DPI that lets the SYN through and kills TLS later still counts
  as «answers». Good enough to tell the three cases apart; not a speed or censorship test.
- `Helper/tests/probe.sh`, `Tests/NetworkCauseTests.swift`.
