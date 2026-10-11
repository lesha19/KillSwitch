# ADR 0029: `killswitch://` links that act

- Status: accepted (Unreleased, issue #23). Decided by the agent; the owner may change it. The
  disconnect rule without protection was decided by the coordinator in the review.
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
| `killswitch://disconnect` | protection on: disconnects; off or paused: refused, «Главная» opens | yes, in the window |
| `killswitch://toggle` | connects when the VPN is off; otherwise as `disconnect` | only to disconnect |
| `killswitch://add?url=<https link, percent-encoded>` | adds or replaces the subscription | always, in the window |

- **Only the CLI's commands without the right.** A link reaches `connect` and `disconnect`
  (`DeepLink.commands`, `CLI.Command` values whose `daemonCommand` has
  `needsAuthorization == false`; a test checks it). The app runs them only through
  `DeepLink.action(for:)`, which has an action for exactly those two (tested). There is no link
  for `protection off`, `pause`, the lists, the switches, install or removal: those words are
  unknown commands. The daemon's console-user rule (ADR 0025) still applies.
- **Connect does not ask.** It only adds the tunnel; protection stays as it is (with protection on,
  pf keeps blocking while it connects). It runs as an automatic connect
  (`KillSwitchControl.coreOnAutomatically`): never the password prompt; if sudo would want a
  password, the usual notification says so. In a state where «Подключить» cannot run (no service,
  no subscription, another VPN, busy) the window opens on «Главная», which shows the state.
- **Disconnect only while protection is on, and only after a question.** With protection on it
  cuts the internet until the next connect, so the window asks «Отключить VPN?», in any state of
  the app (whether the app is in front says nothing about who opened the link). With protection
  off, paused, or standing by next to another VPN (ADR 0018), disconnecting would let the traffic
  out without the VPN — the same as turning protection off, which no link may do — so the link is
  refused (logged, «Главная» opens), even though a question would be shown. The state is taken
  from `ks state` (`KillSwitchControl.state == .on` and not standby), not from the summary, so a
  connecting or stuck VPN is judged by protection too. `toggle` follows the same rule.
- **A subscription is never added silently.** `add` always opens the window with a sheet: the
  address in large type, the link masked (`https://host/•••••abcd`), and one line that KillSwitch
  will contact that address at once, so its owner sees the Mac's IP address and device id
  (the HWID headers). With a subscription already there the title is «Заменить подписку?» and the
  current link is shown masked. Only «Добавить» / «Заменить подписку» stores it, through
  `VPNClient.setURL`, the same checks as a link typed in Settings.
- **A replacing link is kept only once it answered** (`SubscriptionChange`, also for Settings and
  QR codes, which go through the same `setURL`). The new link is fetched first, never through the
  old subscription's backup link; only a successful fetch writes it to the keychain, starts the
  status over and replaces the cache. A failed fetch leaves the old link, its status and its
  servers, and is not recorded as a failed update of the old one. A first link is still kept
  before its fetch, so the timer tries it again. «Отмена» is disabled while the fetch runs: the
  change happens whole or not at all. The check of «Начало работы» (`VPNClient.check`) follows
  the same order.
- **The address shown.** `add` takes exactly one `url` item: at most 2048 characters, printable
  ASCII only (no lookalike letters, no line breaks), `https` only, no user name or password
  (`https://bank.com@other.host` would read as bank.com). The host must be a DNS name (≤ 253
  characters, ≥ 2 labels of 1–63 letters, digits and inner hyphens, the last one letters or
  `xn--…`), a dotted-quad IPv4 address without leading zeros, or a bracketed IPv6 address;
  `0x7f.1`, `2130706433`, `127.1`, `.` and the like are refused. It is shown in ASCII (`xn--…`),
  because `URLComponents.host` decodes punycode and a lookalike name would read as the real one,
  with the port when it is not 443 (`trusted.com:8443`), on one line truncated in the middle.
- **Strict parameters.** Scheme and command are case-insensitive; nothing else is. Section and VPN
  links take no path (one pane for `settings`), no query, no fragment, user or port.
- **Logging.** Unknown, malformed, refused, throttled and done links write one line to the unified
  log (subsystem `com.lesha19.KillSwitch`, category `link`): the command or the reason, never the
  link; the host of an `add` only as a private value.
- **Questions never block.** One at a time: while a sheet waits, further acting links are ignored.
  At most one link every 2 seconds is taken (`DeepLink.Throttle`), so a page looping links cannot
  keep taking the front or keep the app from ever being idle for an update. A question is dropped
  after 2 minutes, or when the app loses the front before the sheet appeared (it never pops up
  later out of context), and before an update quits or relaunches the app
  (`Router.dropSheets` before `UpdateRelaunch.closeSheets`, else the binding brings the sheet back
  and AppKit refuses to quit). A question is not opened over «Начало работы». An answer that comes
  late closes only its own sheet (by request id). Neither sheet has a default button: a link
  opened while the person types is not confirmed by Return. The state is checked again when the
  person confirms.

## Consequences

- `killswitch://whatever` and `killswitch://settings/nope` no longer open the window: unknown links
  do nothing (they used to fall back to the window and «Общие»).
- A provider's «Открыть в KillSwitch» button works with `killswitch://add?url=` + the
  percent-encoded https subscription link. INCY's `incy://add/…`, `crypt1` and status links are
  not supported; a link cannot return a status (the CLI and Shortcuts do).
- A script that disconnects needs the CLI (`killswitch disconnect`) or the shortcut «Отключить
  VPN»: through a link the person is asked each time, and never while protection is off.
- Replacing a subscription in Settings with a link that does not answer now keeps the old one
  (it used to be overwritten before the fetch).

## Manual checks (Developer ID build, not on the owner's live VPN)

1. `open 'killswitch://connect'` with the VPN off and protection on → connects, no dialog.
2. `open 'killswitch://disconnect'` → the window shows «Отключить VPN?»; Return does nothing; Esc
   cancels; «Отключить» disconnects and protection stays on. With protection paused → no sheet,
   «Главная» opens, the VPN stays up.
3. `open 'killswitch://add?url=https%3A%2F%2Fsub.example.com%3A8443%2Fs%2Fkey'` → the sheet shows
   `sub.example.com:8443`; «Отмена» stores nothing. With a subscription: «Заменить подписку?», the
   current link masked; a link that does not answer leaves the old subscription working.
4. `open 'killswitch://pause?minutes=5'`, `killswitch://off` → nothing happens;
   `log show --predicate 'subsystem == "com.lesha19.KillSwitch" && category == "link"'` shows the
   refusal without the link. Ten `connect` links in a second → one taken.
5. A `disconnect` sheet left open, then an update installed («Установить и перезапустить») → the
   sheet goes, the app quits and comes back.
