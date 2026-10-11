# ADR 0029: `killswitch://` links that act

- Status: accepted (Unreleased, issue #23). Decided by the agent; the owner may change it.
- Date: 2026-10-11
- Research: `docs/research/incy-2026-10.md` (idea 2: URL scheme commands and import)
- Builds on: ADR 0008 (links open a section), ADR 0025 (the CLI's command set and rights),
  ADR 0022 (a subscription link is a secret)

## Context

Until now a `killswitch://` link only chose a section of the window (ADR 0008). Issue #23 asks for
links that connect, disconnect, toggle the VPN and add a subscription, so a provider can put
«Открыть в KillSwitch» on a site or in a bot, and scripts (Alfred, Raycast) can drive the VPN.

A link is input from a stranger: any web page can open it (browsers ask once, and may remember
"always allow"), and any program can open it silently with `open killswitch://…`. The rules of the
product still hold: the VPN must not drop by surprise, traffic must not leak, and protection is
loosened only by an administrator.

## Decision

The links (`App/Core/DeepLink.swift`, unit-tested; the app side is `App/DeepLinkViews.swift`):

| Link | What happens | Asks |
| --- | --- | --- |
| `killswitch://` | the window comes forward | no |
| `killswitch://{home, servers, traffic, leaks, log, about}` | that section | no |
| `killswitch://settings[/{general, vpn, protection, advanced}]` | that pane (no pane: «Общие») | no |
| `killswitch://setup` | «Начало работы» | no |
| `killswitch://connect` | connects, as the shortcut «Подключить VPN» | no |
| `killswitch://disconnect` | disconnects | yes, in the window |
| `killswitch://toggle` | connects when the VPN is off; otherwise as `disconnect` | only to disconnect |
| `killswitch://add?url=<https link, percent-encoded>` | adds or replaces the subscription | always, in the window |

- **Only the CLI's commands without the right.** A link reaches `connect` and `disconnect`
  (`DeepLink.commands`, `CLI.Command` values whose `daemonCommand` has
  `needsAuthorization == false`; a test checks it). There is no link for `protection off`,
  `pause`, the lists, the switches, install or removal: those words are unknown commands.
  The daemon's console-user rule (ADR 0025) still applies, since the app sends the same commands.
- **Connect does not ask.** It only adds the tunnel; protection stays as it is (with protection on,
  pf keeps blocking while it connects). It runs as an automatic connect
  (`KillSwitchControl.coreOnAutomatically`): never the password prompt; if sudo would want a
  password, the usual notification says so. In a state where «Подключить» cannot run (no service,
  no subscription, another VPN, busy) the window opens on «Главная», which says why.
- **Disconnect asks, in any state of the app, foreground or background.** With protection on it cuts
  the internet until the next connect (a page could otherwise keep the person offline); with
  protection off or paused the traffic goes out without the VPN, which is the leak the product
  exists to prevent. The sheet says which of the two will happen (`DeepLink.disconnectWarning`).
  Whether the app is in the front says nothing about who opened the link, so it is not a factor.
  `toggle` follows the same rule: connecting at once, disconnecting after the question.
- **A subscription is never added silently.** `add` always opens the window with a sheet: the
  subscription's host in large type, the link masked (`https://host/•••••abcd`), "replaces the
  current one" when there is one. Only «Добавить» / «Заменить подписку» stores it, through
  `VPNClient.setURL`, the same checks as a link typed in Settings; importing new servers asks for
  the password as before.
- **Strict parameters.** Scheme and command are case-insensitive; nothing else is. Section and VPN
  links take no path (one pane for `settings`), no query, no fragment, user or port. `add` takes
  exactly one `url` item: at most 2048 characters, printable ASCII only (no lookalike letters, no
  line breaks), `https` only, a host, no user name or password (`https://bank.com@other.host` would
  read as bank.com). The host shown is the ASCII form (`xn--…`), because `URLComponents.host`
  decodes punycode and a lookalike name would read as the real one. Anything else is refused.
- **Unknown or refused links do nothing** but write one line to the unified log (subsystem
  `com.lesha19.KillSwitch`, category `link`): the reason, never the link. Accepted links log the
  command name; for `add` the host, and that as a private value. The subscription link is not logged.
- **One question at a time.** While a sheet waits, further acting links are ignored (logged), so a
  page cannot stack dialogs. Neither sheet has a default button: a link opened while the person
  types is not confirmed by Return. The state is checked again when the person confirms.

## Consequences

- `killswitch://whatever` and `killswitch://settings/nope` no longer open the window: unknown links
  do nothing (they used to fall back to the window and «Общие»).
- A provider's «Открыть в KillSwitch» button works with `killswitch://add?url=` + the
  percent-encoded https subscription link. INCY's `incy://add/…`, `crypt1` and status links are
  not supported; a link cannot return a status (the CLI and Shortcuts do).
- A script that disconnects needs the CLI (`killswitch disconnect`) or the shortcut «Отключить
  VPN»: through a link the person is asked each time.

## Manual checks (Developer ID build, not on the owner's live VPN)

1. `open 'killswitch://connect'` with the VPN off and protection on → connects, no dialog.
2. `open 'killswitch://disconnect'` → the window shows «Отключить VPN?»; Return does nothing; Esc
   cancels; «Отключить» disconnects and protection stays on.
3. `open 'killswitch://add?url=https%3A%2F%2Fsub.example.com%2Fs%2Fkey'` → the sheet shows
   `sub.example.com` and `https://sub.example.com/•••••`; «Отмена» stores nothing.
4. `open 'killswitch://pause?minutes=5'`, `killswitch://off` → nothing happens;
   `log show --predicate 'subsystem == "com.lesha19.KillSwitch" && category == "link"'` shows the
   refusal without the link.
