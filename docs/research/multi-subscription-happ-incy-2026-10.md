# Multi-subscription handling in Happ and INCY (2026-10-14)

Scope: how Happ and INCY hold many subscriptions at once, show all servers in one place, let the user pick a
server, and which routing applies when servers of different subscriptions coexist. Input for KillSwitch's
"many subscriptions, pick any server, routing only from the subscription, no automatic replacement" work.
Complements `incy-2026-10.md` (not repeated here).

## 0. Limits of this research

- Both apps are closed source. Evidence is provider docs (happ.su dev-docs/FAQ, docs.incy.cc = repo
  `INCY-DEV/incy-docs`), the INCY platforms README, and a Telegram release-notes digest for Happ. No app was run.
- The docs are written for providers, so the user-facing UI (screen layout, rename/reorder/delete flows) is thin.
  Unknowns are marked "?". Statements marked "(inferred)" are my reading, not a source sentence.
- Happ's macOS app is the same codebase as iOS (App Store listing); the separate desktop client is
  Windows/Linux (`Happ-proxy/happ-desktop`). Desktop UI specifics are not documented.
- `happ://add` is NOT described in the docs I could fetch. Documented: `happ://crypto...` (encrypted sub),
  `happ://routing/add|onadd/{base64}`, `happ://routing/off`. Adding a subscription "via deep link" is listed in the
  FAQ without the URL format (?).
- KillSwitch column: taken from `incy-2026-10.md` (0.14.2 state) and the 14.10 code-read note (single
  subscription, URL in Keychain). Not re-verified in code for this file; "?" where unknown.

## 1. Feature table

| Question | Happ | INCY | KillSwitch now |
|---|---|---|---|
| Add a subscription | "+" top right of main screen; clipboard, QR, deep link; plain URL or encrypted `happ://crypto` | URL, clipboard, QR, share link; `incy://add/{url}`, `incy://import/{url}`, `incy://crypt1/...` | URL / paste; one subscription |
| Many subscriptions | Yes. Main screen "Server List" shows each subscription as a block with its own header; manual servers form their own list | Yes. Home and Servers screens show each provider list; manual servers are a separate group | No: single subscription |
| Collapse | Block collapsible; provider can forbid (`subscriptions-collapse: 0`) or force-expand (`subscriptions-expand-now: 1`) | Per-subscription collapse plus "Collapse all"; "Keep expanded" per subscription (provider default, user can override in three-dot menu) | n/a |
| Name shown | `profile-title` header or `#profile-title:` body line, plain or base64, max 25 chars; fallback ? | `profile-title`; subscription name as fallback | `profile-title` read |
| Pick a server | Tap a row in any block; swipe right on a row for actions (ping, share) | Tap a server in the list; sort per subscription (mobile) or global (desktop) | List with "Лучший" |
| Ping all / one | Speedometer icon in each subscription header (whole sub); swipe row (single); "Check Current Connection"; "Ping on Launch" for all servers; provider `subscription-ping-onopen-enabled` | Per-subscription ping settings on mobile, global on desktop; auto-ping after update | Core delay test |
| Ping methods | ICMP (tunnel off), TCP, via Proxy GET (default) / HEAD; display ms or status icon | `incy`, tcp, proxy_head, proxy_get, icmp | ? |
| Sort | `subscriptions-sort-type`: without / ping / alphabet, per subscription | `sort-order`: none / ping / name; per subscription on mobile, global on desktop | Fixed order |
| "Fastest" / auto | No built-in cross-subscription fastest. Provider header `subscription-autoconnect` + `-type` lastused / lowestdelay / random picks a server at launch. A JSON config with its own load balancer is passed to Xray as is; Desktop 2.14.0 pings each outbound of such a config and shows the best | Roadmap only. Full Xray JSON with balancers (leastPing) + observatory works; each array element becomes one "server" | "Лучший", auto-failover (to be dropped for cross-sub) |
| Update per subscription | `profile-update-interval` (hours) per subscription; global "auto-update all" switch plus provider `subscription-auto-update-enable`; missed update runs at next launch | Header-driven per subscription | 12 h default, header-driven, one sub |
| Delete / rename / reorder | Delete documented only by its effect (routing profiles and cached geo files of that subscription are deleted in cascade). Rename ?; reorder ? | ? | n/a |
| Hide server details | `hide-settings: 1` blocks viewing/editing server config; sharing only if not hidden/encrypted | `hide-url` | not handled |
| HWID | On by default; provider can force (`subscription-always-hwid-enable`); HWID-bound links; daily Provider ID check | HWID headers | same headers (Remnawave) |
| Routing source | One routing profile set per subscription ("Control Panel"), isolated lifecycle; `routing` header or body line `happ://routing/onadd/{base64}` | Global routing toggle and profile list; profiles via `routing` / `autorouting` header or body; each bound to its subscription | RU rules injected by the app (issue #8 plans "only from the sub") |
| JSON subscriptions | 0 or 1 bundled routing profile, not editable or disableable by the user; JSON passed to Xray 1:1, app routing rules not applied; only geo files and tunnel DNS are app-controlled | Full Xray config passed "almost unchanged"; app patches inbounds, adds `stats`, adds direct rules for DNS servers when observatory + balancers exist | Xray sidecar planned (#10) |

## 2. Mixed servers: whose rules apply, same names

Happ:
- The routing doc states the model: "modular management at the subscription level"; every subscription has its own
  isolated rule set and profiles, applied only on reconnect. So connecting to a server of subscription A applies
  A's rules (inferred; no sentence says "rules follow the selected server"). Rules never merge across
  subscriptions.
- Switching to a server of another subscription means a reconnect, which also switches the rule set (inferred).
- Same-name servers across subscriptions: not documented (?). A same-name routing profile is overwritten, but only
  inside its own subscription.
- Manual servers have their own rule set too (the doc calls the list `Server-List`).

INCY:
- Profiles are "bound by local subscription ID, so identical names in different subscriptions remain isolated";
  label is `Profile [<profile-title>]`. A provider rename updates the label.
- Which profile is active when servers of different subscriptions are mixed: the docs show one selected profile and
  a global routing toggle; whether picking a server switches to that subscription's profile is not stated (?).
- Same-name servers: not documented (?). Within one subscription, identical WireGuard `.conf` entries collapse into
  one server; otherwise duplicates are not discussed.

## 3. Common pattern

1. The subscription is the unit: a block with its own title, quota, update interval, sort, ping and collapse
   state; servers are grouped under it, not merged into one flat list.
2. Choosing a server is a tap in a block. Nothing switches servers across subscriptions. Auto choice exists only as
   (a) a provider-sent launch-time rule in Happ, (b) a balancer inside a provider's own JSON/Xray config.
3. Routing belongs to the subscription (header `routing` / body line); deleting a subscription takes its profiles
   and geo files with it. Rules are not merged between subscriptions.
4. Ping is a per-subscription action (header button) plus optional ping-on-open.
5. The provider steers the UI through headers (collapse, sort, autoconnect); INCY lets the user override, Happ's
   JSON mode does not.

## 4. Recommendations for KillSwitch

1. Model: list of subscription blocks plus a "Manual" block. Server identity is (subscription ID, server key),
   never the name, so same-name servers stay separate.
2. Rules follow the selected server's own subscription (strict isolation). Switching to another subscription is a
   reconnect with that config; show "rules from: <subscription>" in the server detail. The app injects nothing.
3. Auto behaviour only inside a subscription: keep its own fastest/auto group (mihomo url-test / Xray balancer)
   working as part of its config; no cross-subscription "best" and no replacement on failure. At most an optional
   per-subscription "last used on launch".
4. Per-subscription actions: refresh, ping-all button in the block header, optional ping on open, sort (as
   delivered / ping / name), update interval from `profile-update-interval`, delete with cascade (config, cache,
   Keychain URL, routing artefacts).
5. Cheap provider-header support from both: `subscriptions-collapse`, `sort-order` / `subscriptions-sort-type`,
   `hide-settings` / `hide-url`, `announce`.

## 5. Sources

Fetched 2026-10-14.
- https://www.happ.su/main/llms.txt (index of Happ docs; `.md` appended to any page gives Markdown)
- https://www.happ.su/main/faq/adding-configuration-subscription.md
- https://www.happ.su/main/faq/ping.md and https://www.happ.su/main/dev-docs/ping.md
- https://www.happ.su/main/faq/share-configuration.md
- https://www.happ.su/main/dev-docs/routing.md
- https://www.happ.su/main/dev-docs/app-management.md (profile-title, update interval, collapse, sort, autoconnect,
  ping-onopen, hide-settings, HWID)
- https://www.happ.su/main/dev-docs/examples-of-links-and-parameters.md (JSON passthrough)
- https://www.happ.su/main/dev-docs/hwid-links.md, provider-id.md, limited-links.md
- https://t.me/s/happ_proxy/126 (release-notes digest: Desktop 2.10/2.14, iOS 4.8/4.9; no mention of grouping or
  per-subscription routing)
- https://github.com/INCY-DEV/incy-docs (cloned): `ru/dev-docs/{routing,autorouting,premium-api,app-management,
  subscription-format,full-xray-config,deep-links}.en.md`, served at https://docs.incy.cc
- https://github.com/INCY-DEV/incy-platforms (README)
- Not verified: actual app screens of either app, rename/reorder of subscriptions, same-name server behaviour,
  which routing profile INCY activates after switching to a server of another subscription.
