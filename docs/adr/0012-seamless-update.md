# ADR 0012: updating KillSwitch never interrupts the VPN

- Status: accepted (0.14)
- Date: 2026-10-10

## Context

The owner: to update he had to turn the VPN off, quit the app and drag the new one into
Программы, while working. Goal: like Mullvad, the tunnel lives in root daemons that do not care
about the GUI app; an update needs no manual steps and does not interrupt the internet.

### What happens today (0.13), from the code

Facts are read from the code at 23ed42c; times marked "derived" were not measured on a Mac (the
agent may not run the helper or the app against the system).

1. **Quitting or replacing the app touches nothing.** `KillSwitchApp`/`AppDelegate` have no
   termination handler (`applicationWillTerminate`, `applicationShouldTerminate`), «Выход» is a
   plain `NSApp.terminate`. The tunnel is mihomo in `local.killswitch.core`, the kill switch is the
   pf anchor `com.apple/killswitch` kept by `local.killswitch` (`ks watch`), DNS is set by that
   watchdog. None of them is a child of the app. So the VPN survives the app quitting and being
   replaced; the reopened app reads `daemon-state` and re-attaches. Nothing to fix here.
2. **Sparkle already updates in place**, but only on a click: `SUEnableAutomaticChecks` (daily,
   `SUScheduledCheckInterval` 86400), `SUFeedURL` on the releases repo, no `SUAutomaticallyUpdate`:
   Sparkle shows its dialog, «Install» quits, replaces and relaunches the app. Dragging from the
   DMG is only the first install (docs/index.html).
3. **The drop comes after the update.** The new app carries a different `Helper/ks`, so
   `HelperVersion.matches` is false and the app asks «Восстановить службу…». That runs
   `install.sh` as root, which:
   - `launchctl bootout system/local.killswitch`: SIGTERM to `ks watch`, whose `on_term` runs
     `shutdown_guard`: with `wifiguard=1` (the default) **every network service on a physical
     port is switched off** (Wi-Fi, Ethernet), meant for the boot window at shutdown. The new
     watchdog turns them on once its rules are loaded (≥ 1 s after `bootstrap` + `sleep 1`); then
     Wi-Fi has to re-associate and get an address: derived 5–15 s without internet, and every
     connection is reset.
   - `launchctl kickstart -k system/local.killswitch.core` whenever `Helper/mihomo` is in the
     bundle, i.e. **always**: the tunnel goes down and up even if the core did not change
     (derived ~1–2 s, connections reset).
   - `ks on` always: a pause or «выключено» set by the user was ended by the repair.
   - `install` of `ks` without `-S`: unlink and copy, not a rename (harmless for the running bash,
     which keeps its inode, but not atomic for a crash in between).
4. **The password.** `install.sh` runs through the admin prompt or, since 0.13, the daemon's
   `install` command behind the authorization right: a password (or Touch ID) on every update.
5. **The daemon (ADR 0010) after an app update.** Its `BundleProgram` is inside the app. A running
   daemon keeps the old binary until it exits (2 idle minutes); while the app keeps sending it
   commands (the menu bar speed every few seconds) it never becomes idle.

## Decision

### Helper: a hot upgrade (`install.sh`, both modes)

- Files go in by `put_file`: a copy next to the target (same root-owned directory), `sync`, then
  `mv` (rename, atomic); unchanged files are not touched. Sudoers as before: temporary file,
  `visudo -cf`, `mv`.
- The watchdog is never stopped with a plain `bootout`:
  - new `ks`, same plist: `launchctl kill HUP`. Since 0.14 `ks watch` traps HUP and `exec`s the
    new file in the same process (no `on_term`, no network-off). A 0.13 watchdog has no HUP trap:
    bash ends on it without running the TERM trap, and launchd starts the new file at once
    (KeepAlive; it ran longer than the 10 s ThrottleInterval).
  - new plist (none so far): the job is marked disabled before `bootout` (the existing
    `watch_disabled` check in `shutdown_guard`, already in 0.13, then leaves the network on), enabled
    again (unless the user had disabled it), `bootstrap`.
  - not loaded: `bootstrap`, as before.
  The pf anchor stays loaded the whole time (it lives in the kernel); the new watchdog's first
  pass compares the hash and reloads with `pfctl -a … -f -` (atomic) only if the rules differ.
  Nothing on this path flushes (`-F`) pf or changes DNS.
- The core restarts only if `mihomo`, `geosite.dat`/`geoip.metadb` (read at start) or its plist
  changed, and only if it is loaded: `kickstart -k` (plist: bootout/bootstrap). Meanwhile pf
  keeps blocking everything outside the tunnel and the system DNS stays on 127.0.0.1 (the watchdog
  restores it only after 5 s down): traffic is blocked, never leaked; derived downtime ~1–2 s.
- `ks _regen` (new, internal, root only, under the core lock): the config again from the kept
  profile and pins; if a new generator writes it differently it is committed, pf reloaded and the
  core told to reread it through its API (`PUT /configs?force=true`, the existing `core_reload`),
  no restart. Same output: nothing happens.
- `install.sh <user>` (first install, «Восстановить службу…») keeps `ks on`; `--upgrade` leaves
  protection as it is.

### `install.sh --upgrade` and the daemon command `upgrade`, without a password

- `--upgrade` only upgrades an installed helper: exit 2 if `/Library/KillSwitch/ks` is missing or
  the sudoers entry names no valid user (that user, and nobody else, gets the rewritten entry);
  exit 4 if the bundled `KS_VERSION` is older than the installed one (`version_lt`). Prints
  `core: kept` or `core: restarted`.
- `HelperCommand.upgrade` (`needsAuthorization == false`): the daemon makes its verified copy of
  its own bundle (the existing `verifiedCopy`: signature with nested code, requirement
  `anchor apple generic`, identifier `com.lesha19.KillSwitch`, team `YR58655PJ7`), compares its
  `Helper/ks` with the installed one (`HelperUpgrade.decide`: not installed → refused, same file →
  nothing, older → refused, otherwise `bash -p install.sh --upgrade` with the sanitized
  environment).
- Why this does not weaken security: the code that runs is the code of the bundle the daemon
  itself was started from, checked against the same requirement the daemon trusts its client
  with; whoever can make our signature appear on a bundle already owns the daemon. What the
  password used to protect — choosing *which* code becomes root's — is decided by the signature
  and the downgrade check: an older signed KillSwitch (with a bug fixed since) cannot be put back
  over a newer helper without the admin. No arguments come from the app, the sudoers user is the
  installed one, nothing widens the rules. `upgrade` is not a ks command and not in sudoers:
  sudo and the AppleScript prompt cannot run it (the password flow stays as the fallback).
- The app (`KillSwitchControl.upgradeHelper`): when the installed helper differs from the bundled
  one and the daemon is allowed, it asks the daemon's build (`version`, CFBundleVersion). An older
  daemon has no `upgrade`: its reads go through `sudo -n` instead so it becomes idle and leaves
  (≤ 2.5 min); then the new one runs `upgrade`. Success: notice «Обновление установлено» —
  «VPN не прерывался.» or, if the core restarted, «VPN переподключился за секунду, защита не
  отключалась.». «Восстановить службу…» is not shown while this runs; it comes back only if the
  upgrade fails or the daemon is not allowed (then the password, but the same non-disruptive
  install.sh).
- The daemon (0.14+) also exits as soon as its executable was replaced (device/inode of the path
  changed) and nothing runs, so the next update's daemon starts within 30 s.

### Sparkle: no manual step

- `SUAutomaticallyUpdate` on by default; «Обновлять автоматически» in «О программе» toggles
  `automaticallyDownloadsUpdates` (Sparkle keeps the choice).
- `QuietInstaller` (`SPUUpdaterDelegate.updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`,
  returns true): a downloaded update is installed and the app relaunched as soon as KillSwitch is
  not the active app (checked every minute). The VPN does not notice (point 1).
- Permissions: Sparkle replaces `/Applications/KillSwitch.app` without asking when the user can
  write the bundle and its folder (an admin user, an app copied by that user). A bundle owned by
  root or another user makes Sparkle ask for an admin once per update; Sparkle does not install
  such updates silently, it falls back to its own dialog (derived from Sparkle's documentation).

## Consequences

- The 0.13 → 0.14 update itself is already seamless when the daemon is allowed: the 0.13
  watchdog dies on HUP and is respawned, the core is restarted only if `mihomo` changed in the
  release. Without the daemon the password is asked once more, but install.sh no longer drops
  the network.
- Tests: `Helper/tests/upgrade.sh` (HUP re-exec vs TERM guard on fakes, `_regen`, `install.sh
  --upgrade` on a fake system: rename with a reader of the old file, no bootout, no pf/network
  calls, core restart only on a new binary, plist path disable→bootout→enable→bootstrap,
  downgrade/not installed/no sudoers user refused, `version_lt`), `HelperUpgradeTests` (decision,
  version order, daemon build, outcome, notice, command), `HelperCommandTests` (upgrade is the
  only non-sudoers command without the right).
- Needs a real Mac (not done by the agent): an update 0.13 → 0.14 with a continuous ping while
  connected (expect no loss; `events.log` without «shutdown: network off»); launchd respawning a
  HUP-killed 0.13 watchdog at once; the notice after ≤ 2.5 min without a password; SMAppService
  still enabled after Sparkle replaced the bundle and launchd starting the new daemon binary;
  `PUT /configs?force=true` not recreating the TUN; a silent Sparkle install while the app is in
  the background, and the prompt for a root-owned bundle; how long a core restart takes when
  `mihomo` changes.
