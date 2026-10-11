# Hardening for 0.20.0 (#37, #50)

Branch `harden-37-50` from `release-0.19.0`. What was changed, what was decided and why, what is
left. Decisions marked "decided by the agent" can be changed by the owner.

## #37

- **Password prompt, verified copy.** `AdminScript.run` turns every bundled `install.sh` /
  `uninstall.sh` into `bash -p -c <fixed text> … <app> <requirement> <script> <args>`: root makes
  a 0700 folder with `mktemp -d` (its own temporary directory), copies the app with `cp -RH`
  (a link is copied as what it points at), checks the copy with
  `codesign --verify --deep --strict --all-architectures -R=<HelperIdentity.appRequirement>` and runs
  the copy's script; the folder is removed on exit. The requirement and the idea are the daemon's
  (ADR 0012, `Runner.verifiedCopy`). The app's own BundleSignature check stays as an early,
  friendlier refusal. Checked by hand: the installed Developer ID app copies in 0.2 s (126 MB) and
  its copy passes the requirement. `AdminScriptTests` run the text on an ad-hoc signed bundle:
  runs from the copy, refuses another signer, an unknown script and a script changed after
  signing, leaves nothing behind.
- **`ks core import` without SUDO_UID.** The password prompt and the daemon give no SUDO_UID.
  Without one the file must be a regular file with one name (`lstat`, link count 1); a file of
  another user is read as that user (`sudo -n -u #uid`, as the refresh path does); root's own file
  (the daemon's copy) only by its real path when every folder on the way, links included, is
  root's and not writable by others (`trusted_path`, the walk of `nb_trusted`).
- **Rule providers.** No real subscription was available. The allow-list was checked against
  mihomo's documented fields and the provider shapes RU subscriptions use (mrs / text / classical
  yaml / inline). `header` is documented and was refused, which made such subscriptions fail
  outright: it is now taken (names `[A-Za-z0-9-]`, up to 8 plain strings each, no control
  characters). `path-in-bundle` stays refused. A check on a real subscription remains open.
- **Xray fuzz test** (`Helper/tests/core-xray-fuzz.sh`). Findings, all fixed:
  1. XHTTP `downloadSettings` (also in `extra`) dialled a second server by name: unpinned, not in
     the servers pf lets out, not approved, so a passwordless refresh could add a server. It is now
     checked, pinned (SNI kept), approved, its `dialerProxy` checked and its sockopt tamed.
  2. DNS servers `udp+local://`, `h2c+local://` (and `" localhost"`, `fakedns+others`) passed the
     filter: `+local` queries go straight out of the core, outside routing and the signature. Any
     `<scheme>+local:`, `fakedns*`, `localhost` (trimmed, any case) is dropped.
  3. A balancer selector `""`/`k`/`ks`/`ks-…` also picks our `ks-direct` freedom outbound, added
     for «Программы без VPN» and not part of the direct signature, while pf lets the core out for
     the split programs: refused, as are such observatory selectors and outbound tags `ks-…`
     (decided by the agent: refusing is clearer than renaming, no panel uses these).
  4. `999.1.1.1` and `01.2.3.4` passed as IPv4 server addresses: pf refuses the first and
     everything is blocked; Xray takes the second for a name. Strict dotted decimal now, and
     0/127/224+ refused like `good_server_ip`.
  5. `customSockopt` (raw socket options, a bound interface among them) is removed like
     `interface` and `mark`.
  6. A line break in a host's name made two names in the list `ks core select` reads: shown as
     spaces.
  Not findings: duplicate tags, unknown protocols and keys, huge or negative ports, deep nesting,
  YAML, BOM, 201 configs, 20 MB+, control characters, `api`/`reverse`/`fakedns` sections, panel
  inbounds, rules to our tags or for our inbounds — each refused here or by `xray run -test` before a
  config is put in place.

## #50

- `put_setting`, `drop_setting`, `ks set` and `log_event` go through `locked_rewrite`: perl,
  `flock` on `<file>.lock`, a temporary file named by pid, `rename`. `install.sh` still migrates
  `coredirect` through `settings.tmp`: it runs once per install, not next to the failover.
- The pause/off flag is a `mktemp` file moved into place; `ks off`/`pause` fail if it cannot be
  written (protection stays on).
- `ks_clean_env` unsets `KS_NOW`, `KS_APPROVE_ALL`, `KS_LOCKED`. The core lock re-execs as
  `KS_LOCKED=$$ exec lockf … ks`; the child believes it only when the value is its parent's pid and
  that parent is `lockf`. Tests set the variables after sourcing ks, so they keep working.
- **NetBird link folders (decided by the agent).** `nb_trusted` now follows every link one by
  one and checks each one's folder. A file, or a folder above the file, that others can change is
  refused as before. A link whose own folder others can write (NetBird's installer puts
  `/usr/local/bin/netbird`, and some Macs, the owner's included, give `/usr/local/bin` to the
  user) is logged in events.log and kept. Reason: launchd runs that path as root; whoever can swap
  the link gets root at NetBird's next start whatever KillSwitch does, so refusing protects
  nothing and only cuts NetBird off on those Macs. To make it strict, treat exit 2 of
  `nb_trusted` like exit 1 in `nb_want`. The real fix on such a Mac is
  `chown root:wheel /usr/local/bin` (the owner's call).
- `ProfileConverter.readInBackground` parses (and encodes the cache copy) on a detached task.
- Left as they are: `dns_locked` can wait up to 30 s on a hung scutil (fails closed; a shorter
  wait would risk a DNS state written half); `probe`, `coreDelay`, `coreProxies` stay open to local
  accounts by design.

## Needs a live check

- The password prompt path on a real install and on an «Восстановить службу…» (the copy runs as
  root in root's temporary directory).
- `ks core import` through the password prompt (reads as the owner with `sudo -u`).
- NetBird on the owner's Mac: events.log shows the link line, NetBird keeps its group.
