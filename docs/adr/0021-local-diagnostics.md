# ADR 0021: A local diagnostics journal and «Собрать отчёт»

- Status: accepted (Unreleased, 0.18.0)
- Date: 2026-10-11
- Owner decision 2026-10-11: step 1 of 2, everything stays on the Mac. «Подробная диагностика»
  (every connection with its destination) is off by default; the owner turns it on on his Mac.
  7 days and about 50 MB. Step 2 (later, not built): an anonymous upload to our own server, on by
  default with an opt-out; so the metrics are machine-readable JSON lines.

## Context

«Скопировать диагностику» is a snapshot of the app's state at the moment of the click. The
problems we chase (sites that open every other time, a tunnel lost after sleep, a core that
restarts) happened minutes or hours before, and `events.log` keeps 500 short lines of corrective
actions only. With Xray (ADR 0020) we also had no counters at all: no traffic, no way to see that
the tunnel carried nothing.

## Decision

- **Where.** `/Library/KillSwitch/diag`, root, `700` (install.sh, `ks watch`, `ks core on`,
  `ks set diag 1` make it). The app never reads it directly: only through `ks diag report`.
- **What, as JSON lines, a file a day.**
  - `metrics-<day>.jsonl`, once a minute: time, helper version, core (`xray|mihomo`), core running
    and its pid, protection, standby, our tunnel up, the chosen server's *name* (`xrayserver`, no
    address), a probe through the core (`http://cp.cloudflare.com/generate_204` via the fetch
    inbound `127.0.0.1:47890`, which always goes to a server, ADR 0016: latency and success), bytes
    up/down since the last line, the primary interface, a signature of interface + router (8 hex
    of SHA-256, not the router's address), the DNS servers in effect, whether verbose is on.
  - `events-<day>.jsonl`: every `events.log` line (`ev: log`), and what the watchdog notices:
    sleep/wake (a gap of more than 30 s in the 1-second loop, `SECONDS` follows the wall clock),
    tunnels up/down, the core's start, stop (with its last exit code or signal) and restart (pid
    changed), protection and standby changes; from the background pass: network change (interface
    and signature), DNS change, helper version change. pf's blocks are not recorded: pf logging is
    not cheap.
  - `access*.log`: Xray's access log, only with «Подробная диагностика» (`diag=1`). Every
    connection with its destination domain. mihomo has no such log here: with it nothing about
    destinations is ever recorded.
- **Cost.** The watchdog's own view (`diag_tick`) compares variables it already has and writes a
  line only on a change. Everything that needs a tool (`scutil`, `curl`, the core's counters) runs
  every 10 s as `ks _diag` in the background under `lockf -t 0` (like `core_rotate_bg`), so the
  1-second loop keeps its pace.
- **Retention** (`diag_tidy`, once a minute): the open access log is put aside under its day
  (copy, then emptied in place; Xray appends) at the day's change or past 20 MB; files older than
  7 days go; then the oldest files until the folder is under 50 MB.
- **Verbose switch.** `ks set diag 0|1` (admin, like the other switches; `diag=0|1` in
  `settings`). With Xray it rebuilds the config and restarts the core (about a second, pf blocks
  meanwhile); switching off also deletes the recorded connections. The config names the access
  log only when the folder exists: Xray refuses to start otherwise (checked: `xray run -test`).
  The error log stays `warning` in `core/core.log`.
- **Xray's stats API.** The config now gets `api` (`StatsService` only, `listen 127.0.0.1:47891`,
  the simple form of Xray ≥ 1.8.12 without an inbound or a routing rule), `stats {}` and
  `policy.system.stats{Inbound,Outbound}{Uplink,Downlink}` merged into the subscription's policy.
  The subscription's own `api`/`stats` are still dropped. `ks core traffic` sums the inbounds
  through `xray api statsquery`, so the menu bar speed can work with Xray too. Only counters: no
  HandlerService or RoutingService, nothing can be changed through it. It listens on loopback
  TCP, so any local program can read (or reset) the byte counters; that is all it exposes. A unix
  socket would close that, but Xray 26.9.30's `api.listen` is an address and port. If another
  program holds the port, `core on` and `_regen` notice it (`xray_api_check`, our own running
  core does not count) and the config goes without `api`, `stats` and the stats policy
  (`core/api-off`) until the port is free again, so the VPN still starts; both are logged.
- **«Собрать отчёт».** `ks diag report <folder>` (passwordless, in sudoers and the daemon) builds
  `KillSwitch-report-YYYY-MM-DD-HHMM.tar.gz`: the journal, `events.log`, `core.log(.1)`,
  `daemon-state`, `settings`, `installed`, `invalid`, `routing.json`, a status (protection, both
  launchd jobs, pf info and our anchor, other VPN, egress), versions (ks, app, Xray, mihomo,
  macOS, Mac model), the network (primary interface, tunnels, `scutil --dns`, routes), and crash
  reports of KillSwitch, its helper and filter, Xray and mihomo from the last 7 days (the
  system's and those of the user who asked: `SUDO_UID` through sudo, the caller's audit uid
  through the daemon, `ks diag report <folder> <uid>`). The user's folder is listed and read as
  that user; every crash file is opened with `O_NOFOLLOW` and read from that descriptor only if
  it is a regular file with one link owned by the expected user (root in
  `/Library/Logs/DiagnosticReports`), so a planted hard link or symlink cannot bring a root-only
  file into the archive. Through sudo the archive is written as the user who ran it; through the
  daemon ks writes into the daemon's root-only folder and the daemon copies that one archive into
  a file the app opened on the Desktop. Root never opens a user's path. The daemon serves the
  report only to root, the console user and the user of our sudoers entry: the journal holds
  every user's connections.
- **Redaction** (`diag_redact`, every file): server addresses and names from `servers`,
  `servers-core`, `servers-manual`, `approved-hosts`, `pins` and the profiles' outbounds/proxies
  (`address`, `server`, `serverName`, `sni`, `host`) become `server-1`, `server-2`… (a pinned
  name and its address the same one; an address that followed one of them in a line as `<old>`);
  then links, UUIDs and keys as `App/Core/Diagnostics.swift` masks them; then every other public
  IPv4/IPv6 address becomes `ip-1`, `ip-2`… (one address, one token across the files: old
  servers in the 7-day events, pf rules in `status.txt`, routes, the core's logs, the access
  log). Loopback, RFC 1918, link-local, ULA, Tailscale's 100.64/10, our TUN's 198.18/15,
  multicast and our own resolvers (`DOH_IPS`, `PROBE_RU`) stay readable. Domains stay: what was
  visited is the point of the access log, recorded only with verbose on.
  Never included: `profile.json`, `profile-xray.json`, `xray.json`, `config.yaml`, `pins`.

## Consequences

- The upgrade to 0.18.0 rebuilds the Xray config (`ks _regen`): it differs (api, stats), so the
  core restarts once (about a second, pf blocks meanwhile). mihomo's config does not change.
  `_regen` puts the new config in place only after `xray run -test` (refused: the running one
  stays, no restart, logged); if Xray ran and does not run and listen on its fetch inbound under
  a new pid within about 5 s, the previous config and its files come back and Xray is restarted
  with them («rolled back» in `events.log`). The gap is the restart itself, about 1 s (worst case
  about 6–7 s with a rollback); install.sh restarts the core once more when the Xray binary or
  its plist changed, and that second restart has no rollback (the old binary is gone).
- Port 47891 on loopback taken by another program: Xray runs without the counters (above).
- Step 2 (upload) can summarise `metrics-*.jsonl` without parsing free text.
