# ADR 0008: one window with a sidebar

- Status: accepted (0.11)
- Date: 2026-10-10

## Context

Up to 0.10 the app had four windows: the main window (`HomeView`), «Начало работы», «Проверка
утечек» and the SwiftUI `Settings` scene with five tabs. Each button opened its own window. The
owner: «Я хочу, чтобы это было одно цельное приложение… Другую кнопку нажимаю, еще одно окно
открывается. Что-то плохо продумано.»

## Decision

- One `Window` scene (id `main`), not a `WindowGroup`: SwiftUI keeps a single instance, and
  `openWindow(id: "main")` fronts it when it is already open. macOS restores its size and place.
  Default 860×640, minimum 720×540.
- `NavigationSplitView`: a sidebar with «Главная · Серверы · Проверка утечек · Журнал защиты»,
  the group «Настройки» with «Общие · VPN · Защита · Дополнительно», and «О программе». The 0.10
  «Помощь» tab is split into «Журнал защиты» and «О программе». Settings panes are sidebar rows,
  not a second level of tabs: one click to any pane, and it reads like System Settings.
- No `Settings` scene. ⌘, (`CommandGroup(replacing: .appSettings)`) opens the window at the last
  settings pane. ⌘0, ⌘L, ⇧⌘L are menu commands, so they work in any section.
- «Начало работы» is a sheet of the window (closable: ✕, Esc). Batch «Изменить… → Применить…»
  sheets and confirmations are sheets/alerts of the window; the widget's off/pause confirmation is
  an alert on the window root, whatever section is shown.
- The menu bar popover stays the quick access (status, connect, servers inline). Anything that
  leads further opens the window at a section.
- Routing is a pure function (`App/Core/Navigation.swift`, `NavigationTests`): command,
  notification button, error button, status button or `killswitch://` link → section, the
  wizard, or "front the window as it is". `Router` (app target) applies it: sets the section,
  calls the `openWindow` captured from the menu bar label, activates the app.
- `killswitch://` URL scheme (Info.plist) for the widget (`widgetURL killswitch://home`) and
  future deep links. A link only changes the visible section or shows the wizard; it never
  changes protection or the VPN, so any program being able to open it is harmless.

## Consequences

- One place for everything; the popover remains for one-click use.
- The window is wider than the 0.10 one (400). Home content is capped at 440 and centred so it
  does not stretch; forms (settings, leak test, log) use the grouped style at full width.
- The last section is remembered in `UserDefaults` (`mainSection`); the 0.10 `settingsTab` key is
  reused for ⌘, — its old value `help` falls back to «Общие».
- UX screenshots (`docs/ux/tools`) render the whole window at each section.
- Not verified by launching the app here (no install on this Mac during the change): window
  restoration, reopening from the Dock, and URL delivery to `NSApplicationDelegate` with a
  SwiftUI `Window` scene need a manual check on the release Mac.
