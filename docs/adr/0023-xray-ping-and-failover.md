# ADR 0023: Xray ping through the observatory, failover by the watchdog

- Status: accepted (Unreleased, issue #32)
- Date: 2026-10-11
- Owner's default decision (#43): switch when the probe fails 3 times in a row or the latency is
  above 3× the median for 2 minutes; never leave the protected state while switching.

## Context

With Xray (ADR 0020) the running config is one host of the subscription; the other hosts are other
configs. There was no latency per server, the app's ping bars and «ping all servers» were off, the
menu bar speed was off (though ADR 0021 already gave `ks core traffic` for Xray), and nothing moved
off a dead server: mihomo's fallback groups (ADR 0005) have no Xray counterpart, since another host
means another config and a restart.

Checked against Xray-core 26.9.30 (the pinned binary, `xray run -test` and a running instance on
loopback):

- `api.services` takes `ObservatoryService`; its only method, `GetOutboundStatus`, answers the
  observatory's last result per outbound (alive, delay in ms, last try, error text). It changes
  nothing. The `xray api` command has no client for it, but it is plain gRPC over cleartext
  HTTP/2: `curl --http2-prior-knowledge` with a 5-byte empty frame gets the answer (macOS curl 8.7
  has nghttp2).
- `observatory` and `burstObservatory` both pass `-test` in one config, but the API then answers
  for one of them only; the docs say to choose one. The owner's Remnawave subscription carries a
  `burstObservatory` (for its own `leastLoad` balancer). With the burst kind a dead outbound comes
  without `alive` and `delay`, a live one with the average delay.
- An outbound no rule names carries nothing but the observatory's probes.

Rejected: a temporary Xray per server with a local inbound each (a second process that pf would
have to let out, a port per host, seconds per test); per-host inbounds on loopback in the running
config (a port per host, Xray does not start when one is taken); `RoutingService` balancer info
(that service can also add routing rules, so any local program could send traffic direct).

## Decision

- **Probe outbounds.** `core_generate_xray` copies every host's server (its first
  vless/vmess/trojan/shadowsocks outbound with a tag; none for one reached through
  `proxySettings`/`dialerProxy`) as `ks-ping-<n>` (n = the host's index), tamed like the running
  host's outbounds (address pinned to the approved IPv4, `sendThrough`, interface and mark
  removed) and appended after the template's outbounds. Every host's address was approved at
  import, so pf and the DIRECT signature do not change; no rule leads to them.
- **One observatory.** The subscription's own (`burstObservatory`, `observatory`, whichever it has)
  also gets the prefix `ks-ping-` in its `subjectSelector`; its interval and URL stay. Without one,
  ours: `https://cp.cloudflare.com/generate_204` (the URL of mihomo's failover groups), every
  minute, all at once.
- **API.** `services: ["StatsService", "ObservatoryService"]`, still on 127.0.0.1:47891 (ADR 0021),
  so any local program can also read which hosts answer and how fast. `api-off` drops both; the
  probes still run, ping says the core did not answer.
- **Reading.** `xray_observe` (curl) and `observe_decode` (a small protobuf reader in Perl) give
  `<tag> <alive> <ms>` for `ks-ping-*` only; the error text, which may name an address, is never
  read. The report (`routing.json`) names each host's `ping` tag.
  - `ks core delay Сервер` → `{"<host>": ms}` of the live hosts; `ks core delay <host>` →
    `{"delay": ms}`, 0 when dead (mihomo's answers, `CoreDelay` unchanged). The last probe, not a
    new test: with our observatory at most a minute old.
  - `ks core proxies` adds mihomo's `alive` and `history` per host, so the server list draws ping
    bars by itself and `Failover.state` sees dead hosts.
- **Failover** (`failover_pass`, `ks _failover`): the watchdog starts it every 20 s under the core
  lock (`lockf -t 0`: skipped while a config is being written), only with Xray, the core running,
  the protection on and not in standby (ADR 0018). It sends the diagnostics probe through the fetch
  inbound, which always goes to the running host (ADR 0016).
  - 3 failures in a row → «no answer». A latency above 3× the median of the host's last 30 answers
    (at least 5; slow answers do not enter the median) for 2 minutes → «slow».
  - A server picked by hand (`ks core select`; without failover state yet, `xrayserver=`) is left
    only when it is dead (3 failures), never for being slow: the person chose it. «Slow» moves only
    off a host failover itself chose or the default first host (no pick: the auto mode). A pick by
    hand starts the failover state over (`manual=`, failures 0) with the 3-minute cooldown from
    that moment, so a just-picked server is kept at least that long.
  - The new host: the live one of the same country — the flag its name starts with — with the
    lowest latency in the observatory; for «slow» only one answering in under half the time.
    Never another country (ADR 0005), never twice within 3 minutes. None: logged once while it
    lasts.
  - The switch is `xray_select`, the same as the person's: `xrayserver=`, the config rebuilt and
    checked, Xray restarted (about a second, pf keeps blocking, protection never goes off).
  - `events.log`: `failover (no answer|slow): A -> B`, `failover (…): A, no live|faster server of
    its country`, `failover failed: A -> B, A kept`; the journal (ADR 0021): `failover` with
    `from`, `to`, `reason` (and `ms`, `usual` when slow). Журнал защиты tells them in Russian.
- **Setting.** `failover=0|1` in `settings`, on by default, `ks set failover` (admin, like the
  other switches), a toggle in Settings › Способ подключения shown with Xray. mihomo's failover
  groups stay as they were (always on, ADR 0005).
- **The app.** Ping and speed are no longer hidden with Xray. With Xray `Failover.state` takes the
  hosts with the chosen one's flag as its group: a switch the helper made becomes the chosen
  server, a notification and the status line as with mihomo; «Серверы … не отвечают» only when
  every host of the country is silent.

## Consequences

- The generated Xray config changes (probe outbounds, observatory subjects, the API service): the
  upgrade's `ks _regen` restarts Xray once (about a second, pf blocks; rolled back if it does not
  come up, ADR 0021).
- Probes to every host of the subscription, through the observatory's own schedule; with our
  observatory one request per host a minute.
- Country is the leading flag in ks; the app also recognises a country by name or code
  (`ServerName`). A host named without a leading flag is never a failover target.
- `ks core select` runs under the core lock too (`core_lock_wanted`): the person's pick waits for
  a failover switch in progress (up to 120 s) and comes after it, the failover pass never waits
  (`lockf -t 0`) and skips its turn while a pick is being made; never two restarts at once, the
  pick by hand is the last word. With mihomo the select (an API call) waits for the lock as well.
- `Helper/tests/core-xray-ping.sh` (generator, decoding, delay, proxies, failover pass, the live
  API against the real binary), `Tests/FailoverTests.swift`, `Tests/ProtectionLogTests.swift`.
