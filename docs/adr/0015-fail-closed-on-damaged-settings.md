# ADR 0015: damaged settings files block everything until they are reset

- Status: accepted (Unreleased, issue #17; the English localisation of #17 is postponed)
- Date: 2026-10-10
- Owner decision 2026-10-10: Mullvad's lockdown on invalid settings; a missing file is not invalid

## Context

The pf rules are built from root files in `/Library/KillSwitch`: `settings`, `allow`, `servers`,
`servers-manual`, `tsrelays`, `core/egress`. `setting()` read a key with `grep`, so a damaged
line silently fell back to a default or to garbage: `lan=` or `wifiguard=x` read as "not 1".
Rules pf refused (an address list with junk) left the old rules in place, or none at all at boot.
A damaged `disabled` flag (`garbage` instead of an epoch) kept protection paused forever. Mullvad
locks down when its settings fail to parse (`MULLVAD_LOCKDOWN_ON_INVALID_SETTINGS`).

0.15.2's install.sh drops the obsolete `coredirect=` line; on a Mac whose settings held only that
line the file is now gone. That must keep meaning "all defaults".

## Decision

- **Invalid** (`root_files_bad` in Helper/ks): a file that exists and is not a regular file (a
  directory, a symlink), is not owned by whoever runs ks (root; the tests run it as the user), is
  writable by group or others, or has a line ks does not write:
  - `settings`: every line `key=value` with a key ks sets and a value it accepts (`lan`,
    `tailscale`, `dns`, `direct`, `wifiguard`, `adblock` = 0|1; `splitapps` as `splitapps_parse`
    takes it; `multihop` = off or a valid name). Blank lines and repeated keys (the last counts)
    are fine. `coredirect=0|1` is accepted and ignored (ADR 0013), for an upgrade in progress.
  - `allow`, `servers`, `servers-manual`: one address or network per line (`valid_addr`); a blank
    line is invalid (pf would get `,,`).
  - `tsrelays`: the same plus comments and blank lines.
  - `core/egress`: ownership and permissions only (any content lets the core out).
- **Missing is fine**: no file is the defaults.
- **Lockdown**: damaged settings block the internet; loopback, DHCP and the local network (not its
  DNS) still work (#83). No tunnel: we cannot know what the person allowed. Rules that pass the check but
  pf still refuses (999.1.1.1) load the same lockdown instead of keeping the old rules.
- `load` names the reason in `/Library/KillSwitch/invalid` (world-readable, the bad files or
  `rules`, removed on a good load) and in events.log. The watchdog compares a stat signature of the
  files (`rules.files`, nanosecond mtimes) every full pass, so a file damaged behind ks's back is
  caught within two seconds; nothing reloads while nothing changes.
- The boot window guard does not believe `wifiguard=0` from damaged settings.
- A `disabled` flag that is not a number is removed (protection on) and logged.
- **Repair**: the app shows «Настройки защиты повреждены» with «Сбросить настройки» while
  protection is on and `invalid` is there. It runs `ks repair` (XPC `repair`, behind the right like
  any change that opens something; not in sudoers): damaged `settings` moves to `settings.bad`
  (root-only, for support) so the defaults apply; the lists keep their valid lines; everything ends
  up root's, not writable by others; `servers` is merged again; rules reload; the core's config
  is rebuilt from the defaults.

## Consequences

- A hand edit with a typo blocks the internet. That is the point; the banner says what to press.
- `servers-core` is not checked: the rules read the merged `servers`.
- Not verifiable without root on a real Mac: pf actually loading the lockdown anchor, the banner
  appearing from the watchdog's file, `ks repair` through the daemon.
