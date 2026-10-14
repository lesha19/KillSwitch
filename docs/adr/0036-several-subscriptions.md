# ADR 0036: several subscriptions at once; each brings its own servers and rules; no automatic server replacement

- Status: accepted (0.20.0, design; implementation pending); supersedes ADR 0005 and the failover
  part of ADR 0023 (automatic server replacement is removed); drops the backup link of ADR 0016
- Date: 2026-10-14

## Context

KillSwitch holds exactly one subscription (`VPNClient`, Keychain `subscription-url`), plus an
optional backup link and «Свои серверы». Pasting a second link replaces the first: on 2026-10-14
adding an iVPN link removed the owner's Stork subscription and with it the Lithuanian server he
uses every day.

The owner (2026-10-14), in his words: a simple app — add my subscriptions, pick the server to
connect through; the main feature is a very advanced kill switch that never lets anything past the
VPN in any case; all sites must work; all configuration (which sites go where, countries, how it
works) comes from the subscription itself, not from the app — paste a link and it works with any.
No automatic server replacement: he switches by hand, or uses a subscription's own «fastest» group.
Nothing special when a subscription fails to update. He does not need the backup link. No limit on
the number of subscriptions was named. Take the main behaviour from Happ and INCY.

Happ and INCY (docs/research/multi-subscription-happ-incy-2026-10.md, from their provider docs;
both closed source) agree: the subscription is the unit; servers are shown in one block per
subscription (title from `profile-title`, own refresh, ping, sort); the user picks a server by
hand; routing belongs to the subscription and is not merged across subscriptions; automatic choice
exists only inside a subscription (a provider's balancer or url-test group); same-name servers of
different subscriptions stay separate because they are keyed by subscription.

Facts from the code (2026-10-14): the helper takes one profile per import (`core/profile.json` /
`profile-xray.json`), approval (`approved-hosts`) is one flat host list, the core kind
(mihomo/Xray) is global, and a server is identified by its name everywhere (`ks core select`,
recents, favourites, multihop, Shortcuts).

## Decision

1. KillSwitch keeps a list of subscriptions. Adding a link adds a subscription; it never replaces
   another one. Each can be refreshed or deleted on its own; deleting removes its link, cache and
   anything derived from it.
2. Servers are listed in one block per subscription, titled by the subscription's `profile-title`
   (else its host), plus the «Свои серверы» block. «Недавние» and «Избранное» stay above, each row
   naming its subscription.
3. A server is identified by (subscription, server), never by its name alone, so «Литва» of Stork
   and «Литва» of another provider are two servers.
4. The rules, DNS and groups in force are those of the subscription whose server is selected; the
   app adds nothing and merges nothing across subscriptions. Choosing a server of another
   subscription reconnects with that subscription's configuration; blocking holds throughout
   (ADR 0035).
5. No automatic server replacement: the app never moves the connection to another server on its
   own. A subscription's own automatic group («самый быстрый», url-test, balancer) works as the
   subscription defines it.
6. The backup link is removed. Fetching through the VPN when the direct fetch fails (ADR 0016)
   stays.
7. A subscription that fails to refresh keeps its last servers and shows the error on its block;
   the other subscriptions are not affected.
8. Servers are re-approved with the administrator password as today, once for all subscriptions
   whose hosts changed.

## Consequences

- The kill switch is unchanged; a switch between subscriptions is one more core restart under
  ADR 0035 blocking.
- What the helper receives per import (the selected subscription's profile, or all of them) and
  how a subscription without an Xray panel behaves in Xray mode are implementation questions for
  the spec.
- Existing users are migrated: the single subscription becomes the first item of the list;
  favourites, recents and the chosen server are re-keyed to it.
- Removed code: failover groups (`x-ks-failover`, `KS-FO-*`), the Xray watchdog failover, the
  backup link UI, Keychain entry and fetch steps, their tests and settings-transfer fields.

## Implementation decisions (2026-10-14, decided by the agent, can be changed)

- The core follows the subscription: a subscription is used in Xray when it answers with Xray
  configs and the Xray core is installed, otherwise in mihomo. Subscriptions that offer both use
  Xray. The «Ядро» choice leaves Settings (owner, 2026-10-14: «обычно нет mihomo, а Xray всегда
  есть»; mihomo goes away entirely after 0.20.0, the app then builds Xray configs from plain
  server lists like Happ and INCY). Choosing a server of a subscription in the other
  core switches the core without the administrator password, because its hosts were approved.
  The owner did not understand the question «one core for all, or per subscription»; per
  subscription is what makes «paste any link and it works» true.
- The helper runs one profile at a time: the selected subscription's (or «Свои серверы»). The
  administrator password approves the hosts and DIRECT signatures of every subscription at once;
  switching to an approved subscription is passwordless. Approval is a set, not one profile.
- «Свои серверы» is its own block with no rules of any subscription: all traffic goes to the chosen
  own server (today's behaviour without a subscription).
- Migration: the single subscription becomes the first item; favourites, recents, the chosen
  server, the Wi‑Fi preferred server and transport overrides are re-keyed to it; the backup link
  and the «Автозамена сервера» setting are deleted.
- «Двойной VPN»: the entry server is one of the selected subscription's servers; switching to
  another subscription turns it off.
