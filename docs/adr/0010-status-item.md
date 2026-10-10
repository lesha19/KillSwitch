# ADR 0010: the menu bar icon is an AppKit status item with a right-click menu

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
