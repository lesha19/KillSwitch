# ADR 0025: `killswitch`, a command-line client of the daemon

- Status: accepted (Unreleased, issue #12)
- Date: 2026-10-11
- Research: `docs/research/mullvad-ivpn-gap-2026-10.md` (rows "CLI", "Status / events for scripting")
- Builds on: ADR 0010 (the privileged daemon and its right)

## Context

Mullvad and IVPN ship a user CLI (`mullvad status --json`, `ivpn connect -f`). KillSwitch has `ks`,
but that is the root helper behind sudoers, not a tool for the person. Issue #12: a non-root CLI
with status (`--json`), connect, disconnect, pause and server choice, authorized exactly as the app.

## Decision

- **Where.** A Swift tool `killswitch` (target `KillSwitchCLI`, `CLI/main.swift`; parsing and
  output in `App/Core/CLI.swift`, unit-tested) at `KillSwitch.app/Contents/Helpers/killswitch`.
  Not `Contents/MacOS`: on a case-insensitive volume `killswitch` is the app's own `KillSwitch`.
  We never put it on PATH; the README shows the symlink the person may make.
- **How it talks.** The same XPC interface as the app (`HelperProtocol`, Mach service
  `com.lesha19.KillSwitch.helper`, `.privileged`), and like the app it accepts only our daemon
  (`HelperIdentity.daemonRequirement`). It sends only the commands below, built as `HelperCommand`
  values, so the daemon's checks (`isValid`, the right) are the ones the app goes through.

  | `killswitch …` | daemon command | right |
  | --- | --- | --- |
  | `status [--json]` | `state`, `core state`, `core proxies` | none |
  | `connect`, `disconnect` | `core on`, `core off` | none |
  | `protection on` | `on` | none |
  | `protection off`, `pause <1…9999>` | `off`, `pause <min>` | `com.lesha19.KillSwitch.widen` |
  | `server list [--json]`, `server select <name>` | `core proxies`, `core select` (Failover path) | none |

  Install, removal, imports, lists, switches and reports stay in the app.
- **Authorization: the same, never weaker.** Whether a command needs the right is
  `HelperCommand.needsAuthorization`, as in the app. The CLI obtains the right in its own
  `AuthorizationRef` (`AppAuthorization`, moved unchanged to `App/AppAuthorization.swift` so both
  targets build it) with the same text in macOS's dialog, and
  the daemon checks the external form as for the app. The right is `shared false`, so the CLI does
  not reuse the app's five minutes, and each run is a new process: every `protection off` /
  `pause` asks again. Without a GUI session (ssh) macOS cannot ask and the command is refused.
- **Who may connect.** The daemon's per-connection requirement becomes
  `anchor apple generic and (identifier "com.lesha19.KillSwitch" or identifier "com.lesha19.KillSwitch.cli")
  and certificate leaf[subject.OU] = "YR58655PJ7"`: the same anchor and team, one more identifier
  we sign. The check of the app bundle before root runs install.sh keeps the app-only requirement
  (`HelperIdentity.appRequirement`), so a bundle signed as the CLI is never taken for the app.
- **Signing.** The CLI has the hardened runtime (project-wide `ENABLE_HARDENED_RUNTIME`), an
  embedded Info.plist for its identifier, and `scripts/release.sh` signs it with
  `--identifier com.lesha19.KillSwitch.cli --options runtime` before the app, then verifies its
  designated requirement and runtime flag, as for the daemon.

## Consequences

- The CLI adds no capability: everything it does without the right, the app (and Shortcuts, and
  the sudoers line of `ks`) already does without a password for the same user. Code injection into
  it is blocked as for the app (hardened runtime, library validation, no `get-task-allow` in
  release builds). The daemon does not tell the two identities apart; a narrower interface for
  the CLI would need the peer's identity per connection and was not worth it for no new power.
- `server select` needs the VPN connected (the server list is the running core's); a choice for
  the next connection stays in the app (its pending choice lives in the app's defaults).
- `connect` starts the core with the server it last used; a server picked in the app while
  disconnected is applied only by the app's own «Подключить».
- The CLI's own texts are English, like `ks`'s usage; the daemon's errors come through as it
  writes them. The app's string catalog is not used by the tool.
- Exit codes follow sysexits: 0 ok, 1 the daemon refused or failed, 64 usage, 69 daemon not
  reachable (not installed, not approved in Login Items, another build), 77 no administrator's
  confirmation (cancelled or unavailable).

## Manual checks (Developer ID build)

1. `Contents/Helpers/killswitch status --json` with the daemon enabled → JSON; with it switched
   off in Login Items → exit 69.
2. `connect` / `disconnect` / `server select <name>` → no dialog; the app shows the change.
3. `pause 5` → macOS's dialog «KillSwitch хочет изменить настройки защиты.»; cancel → exit 77,
   nothing changed. Over ssh → exit 77 without a dialog.
4. A copy of the tool re-signed ad hoc or by another team → the daemon invalidates the connection.
