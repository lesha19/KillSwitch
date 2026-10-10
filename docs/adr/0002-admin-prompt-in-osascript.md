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
