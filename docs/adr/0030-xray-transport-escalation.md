# ADR 0030: transport escalation with Xray, inside the failover pass

- Status: accepted (Unreleased, issue #20); steps 3 and 4 of the ladder dropped by ADR 0036: step 3 (another host at the same address) and step 4 (another server) are server changes, and the owner decided (2026-10-14) not to keep step 3 either: the subscription's config must work by itself, the app does not manage it. The pass escalates within the running host only (fingerprint, then its other outbound)
- Date: 2026-10-11
- Decided by the agent («разрабатывай без спроса», roadmap #43); the owner may change any of it.

## Context

Issue #20 (from the Mullvad/IVPN gap research): when connecting fails, step through fingerprint →
transport (TCP / xHTTP) → next server, on top of ADR 0005/0007, visible in Журнал защиты.

What already exists with Xray, the main way: ADR 0023's failover pass (every 20 s, a request
through the running host; 3 failures → the fastest live host of the same country by the
observatory; «slow» never moves off a pick by hand; never twice within 3 minutes) and ADR 0007's
per-server fingerprint and multiplexing overrides, which exist only for mihomo (with Xray the
Settings list is empty).

Constraints: the VPN must not drop and nothing may leak: every step keeps pf blocking (fail
closed), and nothing may need the admin (no new pf address, no change of what goes DIRECT,
KS-10). One state machine, no flapping.

What the subscription really allows:

- **Transport is the server's choice.** A client cannot invent xHTTP for a server that only speaks
  TCP. Only what the subscription offers counts: in the owner's Remnawave panel each host carries
  `LT_1` (Reality over TCP, the first outbound: what no rule takes) and `LT_1_FB` (Reality over
  xHTTP) to the same address; other panels make a host per inbound (`🇩🇪 TCP`, `🇩🇪 XHTTP`).
- **The fingerprint is the client's.** uTLS mimicry of a browser's ClientHello; neither TLS nor
  Reality servers check which one. Changing it touches nothing but the ClientHello.
- **Multiplexing needs the server** (sing-mux / XUDP mux on the server side); trying it blind
  breaks a working server.

## Decision

The escalation is part of `failover_pass` (ADR 0023), not a second machine. All evidence comes
from the observatory, so no step is a blind restart.

- **Probes of the alternatives, only while the server fails.** `core_generate_xray` knows, for
  the running host, its server (the first proxy outbound) with two other fingerprints — from the
  subscription's own, chrome, firefox, safari, minus the one in use — and its other outbounds to
  the same address over another network (`raw` = `tcp`), plus the subscription's own first one
  when another leads: at most 3. Outbounds reached through another one, with an xHTTP download
  server (`downloadSettings`, an address not checked like the servers'), or with a tag holding a
  control character are never alternatives; a running server with a download server has none.
  Normally only their number goes into the report (`escalable`). Once the pass has **armed** them
  (2 failed checks in a row and the server's own probe dead: one rebuild, Xray answers for the new
  probes within a second, measured) they are copied as `ks-ping-<n>-fp-<fp>` / `ks-ping-<n>-t<j>`,
  tamed like ADR 0023's probes, no rule leads to them, the `ks-ping-` prefix of the observatory
  covers them, and the report lists them (`variants`, the subscription's own way marked
  `original`). Not permanently: three ClientHellos to one address every minute are themselves
  something DPI can notice, and they cost handshakes. The report also gives the running host's
  `fingerprint` and `lead`, and every host's `transport` and `endpoint` (the index of the first
  host whose server has the same address; no address in the report).
- **The ladder**, only for «no answer» (3 failures in a row), only with the probes armed, and only
  while the running host's own probe (`ks-ping-<n>`) has a result and it is dead — if it answers,
  or there is no result yet, the problem is not its shape and the server step comes as before:
  1. **fingerprint**: the alternative fingerprint whose probe answers fastest;
  2. **transport**: the other outbound of the host whose probe answers fastest becomes the first
     (swapped with the current first server, so the default route and the fetch go through it;
     the fingerprint found for the old one is forgotten);
  3. **another host at the same address** (same server, another transport): preferred among the
     live hosts of the country, even when slower; logged `failover (no answer, same server)`;
  4. **another server of the country**: ADR 0023 unchanged.

  Each of 1 and 2 at most once per outage (until the running host answers again), and any two
  steps at least 3 minutes apart (ADR 0023's cooldown, shared). A way a step leaves is noted
  (`left-fp`, `left-lead`) and not gone back to by a step for 6 hours: no ping-pong. A server
  picked by hand stays picked through 1 and 2: they keep the person's choice and fix only how it
  is reached. «Slow» never arms or steps (a fingerprint does not make a server faster). If no
  alternative answers (an address blocked outright), step 4 comes at the 3rd failure as before.
- **Limits.** Arming, a step and settling (below) each rebuild the config: at most 3 an hour and
  10 a day per host, failed attempts included (`$CORE_DIR/escalation-steps`). Past that, only the
  server switch of ADR 0023. A flaky network (3 failures, an answer, again, for 6 hours: tested)
  gives 5 rebuilds.
- **Settling.** Once the running server's own probe answers again: if nothing was changed, the
  extra probes go after 15 minutes of answers (one rebuild). If a fingerprint or transport was
  changed, back to the subscription's way once its probe (`original`) has answered for 30 minutes
  without a break, the probes off with it (`escalate settled`). While the original stays blocked
  the way that works is kept and the probes keep watching it: memory that simply expired would
  put the server back on a blocked way, an outage a day. What other servers remember goes after
  a day (they have no probes to prove it either way); left ways after 6 hours.
- **Double VPN (ADR 0027).** The alternatives' probes are dialed through `ks-entry` like every
  other probe but the entry's own, so nothing dials the exit directly. While the entry's probe is
  dead, no step at all: the entry is what is down, not the exit's fingerprint or transport. The
  entry and own servers («(свой)») are never a new exit; names `valid_name` would refuse are
  skipped (and never written to the memory file).
- **Memory.** `$CORE_DIR/escalation` (root, 600): `net=<interface and router>`, then
  `<host>\t<kind>\t<value>\t<epoch>` with kind `probe`, `fp`, `lead`, `left-fp`, `left-lead`.
  The generator builds `fp` and `lead` into every host (the running config and every host's
  probe, so ping bars and failover see what is really used), after checking them: a fingerprint
  from the list (chrome firefox safari ios android edge 360 qq random randomized), a `lead` that
  is any other usable outbound of that host to the same server as the subscription's first one
  (whichever led when it was found); anything else is ignored, never a refused build. A new network (`net_sig` differs) forgets it all; the config is rebuilt only if
  something was remembered (`escalate reset (network changed)`).
- **Applying a step**: the pass writes the memory it would have (`escalation.next`), the config
  is built from that file through `core_rebuild … switch` (refused if DIRECT changed, which it
  cannot), and only then the memory and the failover state (`failover.next`) take its place: a
  kill in between leaves the old memory with the old or the new config, both the same DIRECT.
  Then the same reload as a server switch: about a second of restart, pf blocks meanwhile, the
  protection never goes off. A config that cannot be built leaves the memory as it was, that
  variant set aside (`escalate failed: …, kept`); the step itself is not used up. Likewise a
  server switch writes the failover state only after it happened (the shape of the release's
  fix): a refused switch (KS-10) keeps a pick by hand one, and that server is skipped for 30
  minutes (`$CORE_DIR/failover-refused`) instead of being retried every cooldown.
- **Nothing new past the VPN.** Every probe and every rebuilt config reaches only addresses
  approved at import; the DIRECT file, egress and the servers for pf are byte-for-byte the same
  with and without escalation, and through every step of the ladder with the real generator
  (tested). Reordering touches proxy outbounds only (the first outbound's kind never changes from
  proxy to direct or back), and a balancer's members — part of the DIRECT signature when one is
  direct, as Remnawave's `fallbackTag: direct` — keep the subscription's order whichever outbound
  leads. (Sorting them instead would change the signatures approved at the last import and ask
  for the password once after the update.)
- **Setting.** `escalate=0|1`, on by default (it acts only on a server that is already not
  working, every step is checked by a probe first, and it does not change where traffic goes);
  `ks set escalate` (admin, under the core lock: it rebuilds), off forgets the memory and drops the
  probes. Independent of `failover`: with failover off, steps 1 and 2 still run, the server is
  never left. Settings › Способ подключения, under the failover toggle, Xray only.
- **Visible.** `events.log` → Журнал защиты in Russian: `escalate (no answer): A fingerprint X -> Y`,
  `… transport X -> Y`, `escalate failed: …, kept`, `failover (no answer, same server): A -> B`,
  `escalate probing: A`, `escalate probing off: A`, `escalate settled: A` (and their `… failed`),
  `escalate reset (network changed)`, `connection escalation: on|off`; the diagnostics journal
  gets `escalate` / `escalate-failed` events and `via=same-server` on a failover.

## Left out, and why

- **Multiplexing.** Needs the server's support; a blind try breaks a server that works, and the
  observatory cannot tell whether the server muxes until real traffic flows. ADR 0007's manual
  switch stays (mihomo).
- **TLS fragmentation, padding, other ALPN, another SNI.** Fragment is a `freedom` outbound
  feature in Xray (`dialerProxy` through a direct outbound): it would touch the DIRECT shape that
  only the admin approves (KS-10, ADR 0013). SNI and ALPN are part of what the server accepts.
- **Inventing a transport.** Only transports the subscription defines for the same server.
- **mihomo.** Its fallback groups (ADR 0005) already move off a dead server inside the core; a
  second escalation there would be a competing machine. The manual overrides (ADR 0007) remain.
- **Per-network memory.** What worked is forgotten on a network change rather than kept per
  network: simpler, and a stale tweak never outlives the network it was found on. Could be added.
- **The person's own fingerprint choice with Xray.** Out of scope (the ADR 0007 list is
  mihomo-only); the automatic choice is shown only in Журнал защиты.

## Consequences

- While the server answers, the generated config is what it was without escalation (only the
  report gains a few keys), so the update's `ks _regen` does not restart Xray for it. Arming adds
  2–5 probe outbounds and as many requests per observatory round to the running server, until
  settled; each arming, step and settling is one restart of about a second (pf blocks), within the
  limits above.
- A running host with an override has its probe on the override too, so its ping is what is used.
- Not verifiable here (the owner's Mac must not lose its internet): a real DPI block that one
  fingerprint passes and another does not; the swap to xHTTP under a real block. `xray run -test`
  takes every generated shape (tests); the steps themselves are tested with a mocked observatory.
- Review round 2 (independent review, no leak or new path found) brought the arming, the limits,
  settling, the left ways, the order of balancer members, writing state only after success, the
  refused-target memory, the download-server and tag checks.
- Tests: `Helper/tests/core-xray-escalate.sh`, `Tests/ProtectionLogTests.swift`,
  `Tests/HelperCommandTests.swift`, `Tests/SettingsBackupTests.swift`.
