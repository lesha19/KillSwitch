# ADR 0002: the admin prompt runs in osascript, not NSAppleScript

- Status: accepted (0.10)
- Date: 2026-10-10

## Context

0.9.1 moved `NSAppleScript.executeAndReturnError` (the "do shell script … with administrator
privileges" behind every password prompt) to a background serial queue, so the app would not
freeze while the prompt is up or install.sh runs. Apple documents NSAppleScript as main-thread
only ("You should access NSAppleScript only from the main thread"). Off the main thread it mostly
works, but the Apple Event machinery it uses is not thread-safe, so a crash or a hung prompt would
be on us. On the main thread the run is synchronous: the whole UI stops for as long as the person
takes to type the password and install.sh takes to run.

Options looked at:

1. A dedicated thread with its own run loop: still not the main thread, so still outside what
   Apple supports.
2. NSAppleScript on the main thread: supported, but brings back the freeze 0.9.1 fixed.
3. `NSUserAppleScriptTask`: only runs scripts from `~/Library/Application Scripts/<bundle id>`,
   meant for sandboxed apps; a file there can be replaced by any program running as the user.
4. `/usr/bin/osascript` as a child process (`Process`), the script on its stdin.

## Decision

Option 4 (`AdminScript.execute`). The script text is the same `AdminScript.source` as before
(every argument a string literal through `quoted form of`), now with
`with prompt "KillSwitch хочет изменить настройки защиты…"`: the right is requested by osascript,
and without a prompt the dialog would name osascript instead of KillSwitch. The text goes through
stdin, so server names and paths do not show in `ps`. stdout is the result; a failure is
osascript's "execution error: <message> (<number>)" on stderr, -128 = cancelled
(`AdminScript.outcome`, unit-tested, plus a test that runs osascript without admin rights).

## Consequences

- Nothing in the app touches NSAppleScript; the main thread is free during the prompt.
- The security model is unchanged: the same commands behind the same macOS authorization dialog.
  The dialog shows osascript's icon with our text.
- Part 2 of ADR 0001 (a privileged daemon over XPC) would replace this path entirely.

## Addendum (0.14.2): the dialog names osascript; only a click may open it

The owner saw the prompt «KillSwitch хочет изменить настройки защиты» under osascript's name and
icon on every launch. Two separate things:

**Why it says osascript.** `do shell script … with administrator privileges` asks for the right
in the process that runs the script; here that is `/usr/bin/osascript`, so macOS shows its name and
icon, our text only through `with prompt`. Alternatives looked at:

1. NSAppleScript in the app, on the main thread: the dialog would name KillSwitch, but the main
   thread blocks for the whole prompt and the root command (install.sh: up to minutes); the app
   stops drawing and gets the beach ball. That is the freeze this ADR removed. Off the main thread
   is unsupported (the Context above).
2. `AuthorizationExecuteWithPrivileges`: deprecated since 10.7, not callable from Swift without
   `dlsym`, runs a path as root with no check of what it is. Rejected for security.
3. `AuthorizationCopyRights` in the app names KillSwitch, but root still needs something to run
   the command: that is the daemon of ADR 0010, which already does exactly this
   (`AppAuthorization`, «KillSwitch хочет изменить настройки защиты.» with the app's name).

Decision: the osascript path keeps osascript's name (not feasible to change without option 1's
freeze or option 2's hole); the fix is to make the daemon path the normal one. 0.14.2 makes the
launch actually register the daemon (SMAppService reads `.notFound` for a daemon never registered,
which 0.14.1 took for "no daemon in this build") and shows the Login Items notice; once the switch
is on, macOS's own dialog naming KillSwitch replaces the osascript one.

**Why at launch.** No launch-time code may ask any more: `AdminGate` (App/Core/AdminGate.swift)
sits in front of both prompts (`adminRun` → osascript, `HelperClient.send` → the right's dialog) and
refuses every request that is not user-initiated, logging the reason either way
(`subsystem == "com.lesha19.KillSwitch" && category == "admin"`). The one automatic caller found in
the code was the resume after «Пауза до переподключения» (`resumeIfReconnected`, run from
`refresh()`), which went through `turnOn()`, a click's path with the password fallback after a
refused `sudo -n`. It now runs `ks on` without that fallback. `AdminGateTests` checks the sources:
launch, refresh and timer functions contain no prompting call, and the osascript and right call
sites each sit behind the gate.

Needs a real Mac: with the daemon not allowed, launch → no password dialog, the Login Items notice
(at most once a day); `log show --last 5m --predicate 'subsystem == "com.lesha19.KillSwitch"'` shows
`daemon register: status …` and no `admin prompt requested` until a click. If a dialog still appears
at launch, that log names what asked for it.
