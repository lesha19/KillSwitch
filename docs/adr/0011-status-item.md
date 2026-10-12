# ADR 0011: the menu bar icon is an AppKit status item with a right-click menu

- Status: accepted (0.13)
- Date: 2026-10-10

## Context

Since 0.9 the icon was a SwiftUI `MenuBarExtra` in `.window` style: a click opens the main
screen (`HomeView`) as a popover (Р3). The owner wants a right click to give a compact menu
(Подключить/Отключить, Самый быстрый, Открыть KillSwitch, Проверка утечек, Выход) while the left
click keeps the popover. `MenuBarExtra` has one action for every click: it cannot tell the right
button apart, and its `NSStatusItem` is private (reaching it through the status bar's windows and
an event monitor works today, but rests on SwiftUI internals).

## Decision

- The icon is our own `NSStatusItem` (`App/StatusItem.swift`), created when the app starts. Its
  button reacts to left and right mouse-up: a left click toggles an `NSPopover` (transient) that
  hosts the same `HomeView(style: .popover)` in an `NSHostingController`; a right click or ⌃-click
  shows an `NSMenu` built from `MenuBarMenu.entries` (`App/Core/MenuBarMenu.swift`, tested).
- Menu: «Подключить» (enabled when the main button would connect) or «Отключить» (connected or
  connecting); «Самый быстрый» (the auto group of ServerPicker, through `choose`, so it also works
  while disconnected); «Открыть KillSwitch»; «Проверка утечек»; «Выход» (quits the app at once,
  as menu bar apps do; the VPN and protection keep running).
- Routing is unchanged (ADR 0008): «Открыть KillSwitch» and «Проверка утечек» go through
  `Router`, which now closes the popover first (`willShowWindow`). The window opener is SwiftUI's
  `openWindow`, captured by an invisible SwiftUI view inside the status button (`MenuBarLabel`);
  the same view draws the summary's template icon into the button, posts the VoiceOver
  announcement (at most every 5 s) and offers «Начало работы» once on a Mac without the service.
- Esc in the popover closes it through a `close` callback (`dismiss` does not reach an AppKit
  popover).

## Consequences

- The right click works without SwiftUI internals; the popover looks and behaves as before.
- Not verified on a running app in this change (the agent may not launch it): that the invisible
  hosting view inside the status button gets `openWindow` (it is inside the SwiftUI app, so it
  should), the popover's size follows `HomeView` (`sizingOptions = .preferredContentSize`), and
  `HomeView`'s `onAppear/onDisappear` still follow the popover. The first manual test of 0.13
  settles it; falling back to `MenuBarExtra` is a revert of one commit.

## Addendum (#51, 0.20.0): closing the window leaves the app in the menu bar

The only scene is a `Window` (ADR 0008), and SwiftUI answers yes to
`applicationShouldTerminateAfterLastWindowClosed` for such an app: the red button quit KillSwitch
and took the menu bar icon with it (the VPN and the protection kept running in the daemons).
Owner's decision, 2026-10-12: closing the window only hides it; while it is closed there is no
Dock icon (a menu bar app); opening it brings the icon back; «Выйти» / «Выход» still quit.

- `AppDelegate` answers no to `applicationShouldTerminateAfterLastWindowClosed` and, when the
  window whose identifier is `MainWindow.id` closes (`NSWindow.willCloseNotification`), sets the
  activation policy to `.accessory`. «Запускать без окна» sets `.accessory` in
  `applicationWillFinishLaunching`, so that launch shows no Dock icon either.
- Everything that shows the window goes through `Router.go` (menus, the popover, ⌘-shortcuts,
  notifications, links, «Начало работы»): it sets `.regular` first, then opens the window and
  activates the app on the next run loop turn. Opening the running app again (Finder, Launchpad,
  Spotlight, `open -a`) goes there too while the window is closed (`applicationShouldHandleReopen`,
  only for `.accessory`; with a Dock icon AppKit's own reopen stays).
- Updates (ADR 0012). The quiet install and the relaunch fire as soon as the app is not active,
  which is always so with the window closed; the relaunched build must not then pop its window up
  mid-work. Right before quitting for an update (`updaterWillRelaunchApplication`,
  `Updater.relaunch`) a closed window (`.accessory`) leaves a time under `relaunchWithoutWindow`;
  the next launch within 10 minutes starts as «Запускать без окна» does, once
  (`StartMinimised.atLaunch`, `UpdateRelaunch.startsWithoutWindow`, tested).
- Sparkle treats an `.accessory` app as a background app and would put a scheduled update's alert
  behind the other apps (`SPUStandardUserDriver`, scheduled-update focus). `UpdateAlertFocus`
  (gentle reminders): with the window closed it takes over the alert, opens the window through
  Router and calls `checkForUpdates`, which brings the waiting alert forward. With the window open,
  and for checks the person started, Sparkle shows it as before. A scheduled alert is rare here:
  with «Обновлять автоматически» the update is downloaded and installed without one.
  Decided by the agent, can be changed: the window comes up with the alert, rather than a
  notification.

Measured with a throwaway SwiftUI app (`local.scratch.closetest`, one `Window` scene with id
`main`, a status item whose hosting view keeps `openWindow`, as here; macOS 15.8.1):

- Without the delegate's answer: closing the window asks the delegate, then the app terminates.
- With it: the process stays; `lsappinfo` shows `Foreground` → `UIElement` after the close,
  `Foreground` again after the reopen, `UIElement` after a second close. The NSWindow's
  identifier is the scene id (`main`).
- Started minimised: `UIElement` from launch, no window; the reopen gives `Foreground` and the window.
- `open -a` of the running app with the window closed: reopen is asked (`hasVisibleWindows`
  false); with the Router answer the window opens and the app is `Foreground` and active. Without
  it SwiftUI's own reopen did the same here, so the answer makes it ours rather than fixes a gap.
  By the time reopen is asked the system has already made the app `.regular` (policy logged in
  the handler, 2 of 2), so with the `.accessory` guard the Router answer does not run there and
  SwiftUI's reopen opens the window; the guard keeps AppKit's reopen for a Dock click as well.
- A URL (`open -a App closetest://…`) with the window closed: the app becomes active first, then
  gets the URL, already `.regular`; no `didResignActive` follows Router's switch, so a link's
  question (DeepLinks, `isStale` on resign) is not dropped by it.
- The window's root view gets `onDisappear` on the close and `onAppear` on the reopen (a counter
  went 1 → 0 → 1), so `KillSwitchControl.openViews` drops and polling slows down as before.
- Focus after the red button: after an activation by `open -a`, the app resigned and the app in
  front before got the front (6 of 6, three runs). After an activation by `NSApp.activate()` from a
  notification (no click), the windowless app stayed in front (3 of 3; `deactivate()` and `hide`
  after the close did not change that). Not fixed: it needs a real click to tell.
- `NSApp.activate()` in the same turn as `setActivationPolicy(.regular)` left the app inactive
  when the window had been closed before (3 of 3 runs; the first open after a minimised start was
  active either way); on the next turn, or with `activate(ignoringOtherApps:)`, it was active.

Not verified on the real app (the agent may not launch it): the click on the status item, the
Sparkle relaunch with the window closed (the mark and the launch that reads it) and a scheduled
update alert with the window closed (read from Sparkle 2's source, not run).
