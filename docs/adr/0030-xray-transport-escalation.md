# ADR 0030: transport escalation with Xray, inside the failover pass

- Status: accepted (Unreleased, issue #20)
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

- **Probes of the alternatives.** `core_generate_xray` copies, for the running host only, its
  server (the first proxy outbound) with two other fingerprints — from the subscription's own,
  chrome, firefox, safari, minus the one in use — as `ks-ping-<n>-fp-<fp>`, and every other
  outbound of the host to the same address over another network (`raw` = `tcp`) as
  `ks-ping-<n>-t<j>` (at most 3). Like ADR 0023's probes: tamed (address pinned, interface and
  mark removed), no rule leads to them, the observatory's `ks-ping-` prefix covers them. No TLS
  (plain or Shadowsocks): no fingerprint step. A server reached through another outbound: none.
  The report gives the running host's `variants`, `fingerprint`, and every host's `transport` and
  `endpoint` (the index of the first host whose server has the same address; no address in the
  report).
- **The ladder**, only for «no answer» (3 failures in a row) and only while the running host's own
  probe (`ks-ping-<n>`) is dead too — if it answers, the problem is not its shape and the server
  step comes as before:
  1. **fingerprint**: the alternative fingerprint whose probe answers fastest;
  2. **transport**: the other outbound of the host whose probe answers fastest becomes the first
     (swapped with the current first server, so the default route and the fetch go through it;
     the fingerprint found for the old one is forgotten);
  3. **another host at the same address** (same server, another transport): preferred among the
     live hosts of the country, even when slower; logged `failover (no answer, same server)`;
  4. **another server of the country**: ADR 0023 unchanged.

  Each of 1 and 2 at most once per outage (until the running host answers again), and any two
  steps at least 3 minutes apart (ADR 0023's cooldown, shared). A server picked by hand stays
  picked through 1 and 2: they keep the person's choice and fix only how it is reached. «Slow»
  never triggers 1 or 2 (a fingerprint does not make a server faster). If no alternative answers
  (an address blocked outright), step 4 comes as fast as before.
- **Memory.** `$CORE_DIR/escalation` (root, 600): `net=<interface and router>`, then
  `<host>\tfp|lead\t<value>`. The generator builds it into every host (the running config and
  every host's probe, so ping bars and failover see what is really used), after checking it: a
  fingerprint from the list (chrome firefox safari ios android edge 360 qq random randomized), a
  `lead` that is one of that host's outbounds to the same server; anything else is ignored, never
  a refused build. A new network (`net_sig` differs) forgets it all; the config is rebuilt only if
  something was remembered (`escalate reset (network changed)`).
- **Applying a step** is `core_rebuild … switch` (refused if DIRECT changed, which it cannot) and
  the same reload as a server switch: about a second of restart, pf blocks meanwhile, the
  protection never goes off. A config that cannot be built leaves the memory as it was
  (`escalate failed: …, kept`).
- **Nothing new past the VPN.** Every probe and every rebuilt config reaches only addresses
  approved at import; the DIRECT file, egress and the servers for pf are byte-for-byte the same
  with and without escalation (tested). Reordering touches proxy outbounds only (the first
  outbound's kind never changes from proxy to direct or back).
- **Setting.** `escalate=0|1`, on by default (it acts only on a server that is already not
  working, every step is checked by a probe first, and it does not change where traffic goes);
  `ks set escalate` (admin, under the core lock: it rebuilds), off forgets the memory and drops the
  probes. Independent of `failover`: with failover off, steps 1 and 2 still run, the server is
  never left. Settings › Способ подключения, under the failover toggle, Xray only.
- **Visible.** `events.log` → Журнал защиты in Russian: `escalate (no answer): A fingerprint X -> Y`,
  `… transport X -> Y`, `escalate failed: …, kept`, `failover (no answer, same server): A -> B`,
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

- The generated Xray config gains 2–5 probe outbounds; the upgrade's `ks _regen` restarts Xray
  once (about a second, pf blocks; rolled back if it does not come up, ADR 0021). The observatory
  sends 2–5 more requests per round to the running server.
- A running host with an override has its probe on the override too, so its ping is what is used.
- Not verifiable here (the owner's Mac must not lose its internet): a real DPI block that one
  fingerprint passes and another does not; the swap to xHTTP under a real block. `xray run -test`
  takes every generated shape (tests); the steps themselves are tested with a mocked observatory.
- Tests: `Helper/tests/core-xray-escalate.sh`, `Tests/ProtectionLogTests.swift`,
  `Tests/HelperCommandTests.swift`, `Tests/SettingsBackupTests.swift`.
