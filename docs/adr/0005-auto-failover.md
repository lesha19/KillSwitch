# ADR 0005: auto-failover with mihomo fallback groups, within the chosen country

- Status: superseded by ADR 0036 (0.20.0: no automatic server replacement; the failover groups are removed)
- Date: 2026-10-10

## Context

TSPU blocks single servers and protocols for hours. With a server picked by hand, mihomo's
`select` group keeps dialling it: the person sees «Защищено» and nothing loads. «Самый быстрый»
(the profile's `url-test`) already moves to a live server, but across countries, which is wrong
for someone who picked a country on purpose (a bank that only works from Lithuania).

Constraints: the kill switch must stay intact (no new pf rule, no DIRECT path); the passwordless
subscription refresh must keep working (it compares a DIRECT signature of the profile's groups).

Checked against mihomo 1.19.32 (the pinned core):

- `fallback` group: "if the current node times out, the first available node in order is used"
  (meta-docs, proxy-groups/fallback); options `url`, `interval`, `lazy` (default true: tested only
  while the group is in use), `hidden`.
- A fallback group takes a manual choice: `PUT /proxies/<fallback>` answers 204 (tried against
  the binary: the REST handler accepts any `outboundgroup.SelectAble`). Source
  (adapter/outboundgroup/fallback.go): the chosen proxy is used while it is alive; once it is not,
  the choice is dropped and the first alive proxy in order is used.
- Health checks dial through each proxy (to its server, the one thing pf lets the core reach).

## Decision

- **The app** groups the main selector's servers by country flag (`Failover.sets`, the same
  `ServerName` the list uses) and puts the sets with two or more servers into the profile as
  `x-ks-failover`. Country recognition stays in one place (Swift), not duplicated in bash.
- **The helper** (`core_generate`) validates the hint (a list of at most 100 lists of 2–500 names,
  each a proxy of the profile, each name in one set; `KS-FO-` names in the profile are refused) and
  adds, after `direct_sig`, a hidden `fallback` group `KS-FO-<n>` per set
  (`url: https://cp.cloudflare.com/generate_204` — the URL KS-DNS already checks — `interval: 120`),
  and appends the groups to the main selector (the first `select` group). They hold only proxies,
  so they cannot send anything DIRECT, and the DIRECT signature does not change: refresh stays
  passwordless. No select group: the hint is ignored.
- **Picking** a server selects it in its group, then the group in the main selector
  (`Failover.path`). A server the main selector points at directly (picked before 0.10 or in the
  grouped list) is moved behind its group once (`Failover.adoption`), passwordless.
- **Watching** (`Failover.state`, after every `ks core proxies`): the chosen server is dead and the
  group uses another → «switched»: the new one becomes the chosen one (and is selected in the group
  so the core keeps it across restarts), a notification (≤ 1 per 10 min) and the status line for
  an hour. Every server of the country dead → «countryDown»: banner and notification with
  «Самый быстрый» / «Выбрать сервер…»; another country is never picked by itself.

## Consequences

- The first refresh after the update imports the hint without a password (servers and DIRECT
  signature unchanged); until then everything works as before.
- A single-server country has no group: the person is told when it is dead.
- The lists the person sees never show `KS-FO-*` (`CoreProxies` keeps them apart).
- `Helper/tests/core-failover.sh`, `Tests/FailoverTests.swift`.
