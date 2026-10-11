# ADR 0010: a privileged daemon over XPC, an authorization right with a timeout

- Status: accepted, implemented; waits for the manual checks below on a real Mac with a Developer ID build
- Date: 2026-10-10
- Owner decision: Р2 «Пароль или Touch ID раз на несколько минут» (`docs/ux/spec.md` §10)
- Builds on: ADR 0001 part 2 (the design), ADR 0002 (the osascript path it replaces)

## Context

Every change that widens what may leave the Mac without the VPN ran `do shell script … with
administrator privileges` through osascript (ADR 0002): one password per change, no Touch ID. Р2
asks for a password or Touch ID at most once every few minutes, without making any widening change
passwordless (option В stays rejected) and without letting another program running as the user do
what the app does.

## Decision

### The daemon

`KillSwitchHelper` (target `KillSwitchHelper`, sources `HelperDaemon/`), a Swift tool without
dependencies at `KillSwitch.app/Contents/MacOS/KillSwitchHelper`. Its launchd plist is
`Contents/Library/LaunchDaemons/com.lesha19.KillSwitch.helper.plist` with `BundleProgram`,
`MachServices` (`com.lesha19.KillSwitch.helper`) and `AssociatedBundleIdentifiers`; the app
registers it with `SMAppService.daemon(plistName:)`. launchd starts it on demand for its Mach
service; it exits after two idle minutes, so after an update the next message starts the new
binary.

**`ks` stays the implementation.** The daemon runs `/Library/KillSwitch/ks` with an argument vector
(`Process`, no shell, cwd `/`, and `HelperCommand.environment` as its whole environment:
`PATH=/usr/bin:/bin:/usr/sbin:/sbin` only, the same as the password prompt's since 0.12.1) and the
bundled `install.sh` / `uninstall.sh` with `/bin/bash -p` for install, repair and removal. ks then
resets the rest itself (`ks_clean_env`, `#!/bin/bash -p`) and checks the arguments of the
passwordless commands once more (`passwordless_args_ok`). The rules, the core config generator
and their 12 test suites (`Helper/tests`) are untouched; moving that logic to Swift would be a
rewrite of the product's core without a reason in Р2. The daemon is a thin, typed, authenticated
gate in front of it. Before it runs `ks` it checks that `/Library/KillSwitch` and `ks` are root's,
not symlinks and writable by nobody else.

### Who may connect: code signing, both ways

- Daemon: every new connection gets `setCodeSigningRequirement`
  `anchor apple generic and identifier "com.lesha19.KillSwitch" and certificate leaf[subject.OU] = "YR58655PJ7"`
  (macOS 13+). The system checks it against the peer's audit token, not its PID, and invalidates
  the connection otherwise. A user process that is not our signed app cannot send a single command.
  Since ADR 0025 the requirement also takes `identifier "com.lesha19.KillSwitch.cli"` (the
  `killswitch` tool, same anchor and team); the bundle check before install.sh stays app-only.
- App: the connection to the Mach service requires
  `… identifier "com.lesha19.KillSwitch.helper" …`, so something else holding the name gets nothing.
- Hardened runtime is on for every target (`ENABLE_HARDENED_RUNTIME: YES`; release.sh already signed
  with `--options runtime`). Without it code could be injected into the app (DYLD variables, a
  debugger) and inherit its connection. The app gains `com.apple.security.personal-information.location`,
  which the runtime requires for the Wi-Fi name (trusted networks). Debug builds keep
  `get-task-allow`, as Xcode adds it; only release builds are a security boundary.

### What it does: a closed set of typed commands

`HelperProtocol` (App/Core/HelperProtocol.swift) has one method per operation and no "run this";
the daemon turns each into a `HelperCommand` (App/Core/HelperCommand.swift, unit-tested), checks
`isValid` (the same rules as Helper/ks: `valid_addr`, `valid_name`, `splitapps_parse`, pause
minutes, switch keys; ks checks again) and maps it to fixed arguments.

| Without the right (what sudoers allowed) | Behind the right (what asked for the password) |
| --- | --- |
| `state`, `probe`, `on`, `netrestore` | `off`, `pause <min>` |
| `core state\|on\|off\|proxies\|traffic\|connections` | `set <switch> 0\|1`, `set splitapps`, `set multihop` |
| `core select <group> <proxy>`, `core delay <name>` | `allow`, `unallow`, `server-add`, `server-remove` |
| `core refresh <profile>` (ks refuses new servers, exit 3) | `core import <profile>` |
| | install / repair (`install.sh`), removal (`uninstall.sh`) |

A test reads the sudoers line of `install.sh` and fails if the two columns stop matching it, in
either direction; `Helper/tests/args.sh` holds ks's own check to the same list. `set adblock`
(0.13) is a switch like the others: it changes what the core refuses, so it stays behind the right.

- **Profiles** come as a file handle the app opened; the daemon copies at most 20 000 001 bytes of
  a regular file into a fresh 0700 directory of root's and gives ks that copy. Root never opens a
  path the user named.
- **install.sh / uninstall.sh** run from a copy of the app bundle in a fresh root-only directory
  (a clone on APFS), checked with `SecStaticCodeCheckValidity` (all architectures, nested code,
  strict) against the app's requirement above. The bundle itself can be written by its user; the
  copy cannot, so nothing can be swapped between the check and the run. The app's own argument
  for the user is ignored: the sudoers entry goes to the user the audit token names.

### Authorization: a right with a timeout, checked by the daemon

The right `com.lesha19.KillSwitch.widen` (App/Core/HelperRight.swift):
`class user, group admin, authenticate-user, timeout 300, shared false, allow-root false,
session-owner false` — `authenticate-admin-nonshared` with five minutes.

1. The app keeps one `AuthorizationRef` for its lifetime and, before a widening command, calls
   `AuthorizationCopyRights` for the right with interaction allowed (off the main thread). macOS's
   own dialog asks for an administrator; within five minutes of the last success it returns at once.
   The app sends `AuthorizationMakeExternalForm` with the command.
2. The daemon recreates the authorization from the external form and calls `AuthorizationCopyRights`
   for the same right **without** interaction. A granted, unexpired right passes; anything else
   gets `notAuthorized` and the app asks again (once).
3. The daemon owns the definition. `config.add.` lets *any* user create a right that does not
   exist yet, so a definition planted before the daemon's first start must not count: at start and
   before every check the daemon compares the stored rule key by key (`HelperRight.matches`) and
   rewrites it as root (`config.modify.`: is-root). If it still differs, every widening command is
   refused.
4. `shared false`: the credential stays in the app's AuthorizationRef; other programs of the
   login session gain nothing from it. The external form only reaches the daemon over the
   connection that passed the code-signing check.

**Why not LocalAuthentication.** `LAContext.evaluatePolicy` (Touch ID with password fallback)
yields a boolean in the user's process. The daemon cannot verify it: any code that can talk to the
daemon could claim "true", so it would be a passwordless path behind a UI. Authorization Services
is the only standard mechanism whose result root can check (authd vouches for it). Touch ID comes
from macOS's own authorization dialog where macOS offers it for such a right; this must be
confirmed on a Touch ID Mac (checklist). If it does not appear, the right still works with the
password once per five minutes, which is Р2's floor.

### Registration and approval (SMAppService states)

| `SMAppService.Status` | `HelperService.Availability` | The app |
| --- | --- | --- |
| `.enabled` | `ready` | commands go through the daemon |
| `.notRegistered` | `needsRegistration` | the wizard's «Установить…» and «Восстановить службу…» call `register()` |
| `.requiresApproval` | `needsApproval` | `HelperApprovalNote` (wizard, Settings › Служба): what to switch on, «Открыть Объекты входа…» (`openSystemSettingsLoginItems`) |
| `.notFound` | `unavailable` | the old path |

Registration never blocks: while macOS waits for the switch, that click still goes through the
password prompt (ADR 0002), so a first install is never stuck on a System Settings step. When the
daemon is ready but does not answer the first command (crashed, an older daemon, a build signed
otherwise) the app falls back the same way; after that, a failure is reported, not retried with the
password (the batch may have partly run).

### Migration and removal

- Existing installs keep `install.sh`'s LaunchDaemons (`ks watch`, the core) and its sudoers line:
  the watchdog is still what keeps the rules in place, and sudo stays the fallback. The daemon only
  takes over what osascript and `sudo -n` did from the app.
- An upgrade from 0.12 gets the daemon with the next «Восстановить службу…» (offered after every
  helper update) or the wizard.
- Uninstall runs `uninstall.sh` (through the daemon or the password), which now also removes the
  right (`security authorizationdb remove`); then the app calls `SMAppService.unregister()`.

### Release

`scripts/release.sh` signs `Contents/MacOS/KillSwitchHelper` with `--identifier
com.lesha19.KillSwitch.helper`, Developer ID and the hardened runtime before the app (inside out,
no `--deep`), then verifies both designated requirements and the daemon's runtime flag. `--check`
also fails without `ENABLE_HARDENED_RUNTIME: YES` or with a daemon plist that does not name
`Contents/MacOS/KillSwitchHelper`.

## Consequences

- One dialog per five minutes for every widening change, Touch ID where macOS offers it; reads and
  passwordless commands stay passwordless.
- A root daemon in Swift is new attack surface: its whole input is the typed commands above, from
  our signed app only, each validated twice.
- Two paths exist until the fallback is removed: the daemon and osascript/sudo.

## Open for the owner

1. Register the daemon on the first widening click too (not only in the wizard and repair)? Today an
   upgraded Mac keeps the password-per-change until «Восстановить службу…».
2. Once the daemon has proven itself: drop the sudoers line and the osascript fallback (then a Mac
   without the approval in Login Items cannot change anything; the wizard would have to wait for it).
3. 300 s is the timeout from Р2 («раз на несколько минут»); it is one constant (`HelperRight.timeout`).

## Manual checks (real Mac, Developer ID build from `scripts/release.sh --sign-only` or a notarized one)

Registration and approval
1. Clean Mac, wizard: «Установить…» → notification «Добавлен фоновый объект», the note appears; the
   install still finishes with one password. Login Items › «Разрешить в фоне» lists KillSwitch.
2. Switch it on → the note disappears within a few seconds (the app open); `launchctl print
   system/com.lesha19.KillSwitch.helper` shows the service.
3. Switch it off again → the note returns; a change asks for the password through osascript.
4. 0.12 → this build over Sparkle: «Восстановить службу…» registers it; the old watchdog keeps running.

Authorization
5. A widening change (e.g. «Адреса без VPN») → macOS's dialog with «KillSwitch хочет изменить
   настройки защиты.»; on a Touch ID Mac: does it offer Touch ID? (record the answer in this ADR).
6. A second change within 5 minutes → no dialog. After 5 minutes → the dialog again.
7. Cancel the dialog → nothing changes, no error banner.
8. Wizard with the daemon enabled: install + import + connect → one dialog.
9. `security authorizationdb read com.lesha19.KillSwitch.widen` shows timeout 300, shared false.
   Planted right: before the daemon's first start `security authorizationdb write
   com.lesha19.KillSwitch.widen allow` as the user → after the first command the stored rule is ours again.
10. Passwordless: connect/disconnect, server choice, ping test, subscription auto-update → no dialog.
    Turning protection off from the widget → the confirmation, then the dialog.

Code signing
11. `codesign -dv --verbose` on the app and on `Contents/MacOS/KillSwitchHelper`: runtime flag, the
    identifiers above, team YR58655PJ7.
12. A client that is not the app (a small Swift tool connecting to `com.lesha19.KillSwitch.helper`,
    unsigned, then signed with another team or with our team but another identifier) → the
    connection is invalidated, nothing runs (`log stream --predicate 'subsystem == "com.lesha19.KillSwitch.helper"'`).
13. An app copy with a changed `Contents/Resources/Helper/install.sh` (signature broken) → «Восстановить
    службу…» through the daemon fails with «Программа KillSwitch повреждена…», nothing installed.
14. Sparkle update with the hardened runtime: check, download, install and relaunch still work;
    the filter and the widget still load.

Removal
15. «Удалить KillSwitch из системы…» → one dialog; afterwards no `/Library/KillSwitch`, no
    `/etc/sudoers.d/killswitch`, no LaunchDaemons, `security authorizationdb read
    com.lesha19.KillSwitch.widen` fails, KillSwitch gone from Login Items.
