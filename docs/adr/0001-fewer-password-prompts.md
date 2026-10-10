# ADR 0001: fewer password prompts without weakening protection

- Status: accepted in part — batching is done (0.9); the privileged daemon is planned below
- Date: 2026-10-10
- Owner decision: Р2 in `docs/ux/spec.md` §10

## Context

Every change that widens what may leave the Mac around the VPN (turning protection off, a pause,
an address without VPN, a server for another VPN program, apps without VPN, double VPN, a new
subscription profile) runs a root command through `NSAppleScript` "do shell script … with
administrator privileges". macOS asks for the admin password every time. Changing three settings
meant three passwords (audit H7-1); first run needed two (install, then import).

The rule that must hold: **no program running as the user may weaken protection silently.** That
is why the sudoers entry written by `install.sh` allows only commands that never widen the rules
(`ks state`, `ks on`, `ks core on|off|state|proxies|select|delay|refresh` — `refresh` refuses new
server addresses with exit 3). Anything that widens them asks for the password.

## Decision

### Part 1 (done in 0.9): one password per batch

- `AdminScript.source(_ commands: [[String]])` joins several commands with `&&` in one
  AppleScript, each argument a string literal passed through `quoted form of`. One prompt, and the
  first failure stops the rest.
- Settings edits lists and switches as a draft in a sheet («Изменить… → Применить…»,
  `BatchSheet`); `Batch.list` / `Batch.settings` (App/Core, tested) turn the diff into
  `ks allow|unallow|server-add|server-remove|set` commands. Adding three addresses and removing one
  is one password.
- The first-run wizard runs `install.sh`, `ks core import <file>` and `ks core on` as one admin
  command (`Onboarding.commands`): one password from a clean Mac to «Защищено».
- Addresses are validated (`Batch.address`) before they reach a root command; the helper checks
  them again.

The security model does not change: the same commands, the same prompt, fewer prompts.

### Part 2 (planned): a privileged daemon with a short-lived right and Touch ID

Not built in 0.9: it replaces the trust boundary of the product and needs its own review and a
test on a clean Mac with a Developer ID build. The design:

1. **Daemon.** A small Swift executable `KillSwitchHelper` inside the app bundle
   (`Contents/Library/LaunchDaemons/com.lesha19.KillSwitch.helper.plist`, `BundleProgram`),
   registered with `SMAppService.daemon(plistName:)`. macOS asks the user once to allow it in
   Login Items; no password per change afterwards. It replaces the AppleScript path only: the
   daemon calls the existing `/Library/KillSwitch/ks` with an argument vector (`Process`, no
   shell), so the rules logic and its tests (`Helper/tests`) stay as they are.

2. **XPC with a code-signing check of the caller.** `NSXPCListener(machServiceName:)` in the
   daemon; every new connection is accepted only if the peer satisfies

   ```
   anchor apple generic and identifier "com.lesha19.KillSwitch"
     and certificate leaf[subject.OU] = "YR58655PJ7"
   ```

   via `NSXPCConnection.setCodeSigningRequirement(_:)` (macOS 13+), which checks the audit token,
   not the PID. A user-level program that is not our signed app cannot connect at all. The app
   must have Hardened Runtime on (today `ENABLE_HARDENED_RUNTIME: NO`), otherwise another process
   could inject code into it and inherit the connection: this is a precondition, not an option.

3. **Narrow interface.** The XPC protocol has typed methods, not "run this command":
   `setSwitches([String: Bool])`, `setList(kind, [String])`, `pause(minutes)`, `turnOff()`,
   `setSplitApps([String])`, `setMultihop(String?)`, `importProfile(fileHandle)`. The daemon
   validates every value again (addresses, app names, minutes) and refuses anything else.
   Profiles are passed as a file handle, not a path, so the app cannot point it at another file.

4. **Authorization with a timeout and Touch ID.** Widening calls require an Authorization
   Services right, e.g. `com.lesha19.KillSwitch.widen`, defined by the daemon at first start
   (`AuthorizationRightSet`) as `authenticate-admin` with `timeout = 300` and
   `shared = false`. The app obtains the right with `AuthorizationCopyRights`
   (`kAuthorizationFlagInteractionAllowed | ExtendRights`) — macOS shows its own dialog, which
   offers Touch ID where macOS allows it for such a right (to confirm on a Touch ID Mac) — and sends the external form to the daemon, which checks
   it with `AuthorizationCopyRights` before acting. Within 5 minutes no new prompt: «авторизоваться
   раз в несколько минут». `LocalAuthentication` alone is not enough here: its result is a boolean
   in the user's process that the root side cannot verify, so it is used at most as UI, never as
   the gate.

5. **What stays without a prompt.** Exactly what sudoers allows today (state, `on`, core
   start/stop/select/delay/refresh). Nothing that widens the rules becomes passwordless — option В
   of Р2 stays rejected.

6. **Migration.** `install.sh` keeps working for repair; the app prefers XPC when the daemon
   answers and falls back to `AdminScript` otherwise. Uninstall unregisters the daemon
   (`SMAppService.unregister`) and removes the right (`AuthorizationRightRemove`).

### Work items for part 2

1. Hardened Runtime on for the app; check Sparkle, the filter and the widget still work.
2. `HelperDaemon` target (Swift, no dependencies), plist, `SMAppService` registration and the
   Login Items explanation in the wizard («Установка»).
3. XPC protocol + client in `KillSwitchControl` behind the same methods it has now
   (`setSwitches`, `setExceptions`, …), so views do not change.
4. Code-signing requirement on the listener; a negative test: an unsigned helper binary and a
   build signed by another team must be refused.
5. Authorization right with timeout and Touch ID; tests for the right definition and for a
   refused/expired external form.
6. Security review of the daemon's argument validation against `Helper/ks`.

## Consequences

- 0.9: noticeably fewer prompts (one per sheet, one for the whole first run), no new attack
  surface.
- Part 2 removes repeated prompts within 5 minutes and adds Touch ID, at the price of a root
  daemon written in Swift, Hardened Runtime and a security review. Until then a pause or turning
  protection off still asks for the password every time — on purpose.
