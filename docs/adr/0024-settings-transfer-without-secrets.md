# ADR 0024: Settings export, import and reset carry no secrets

- Status: accepted (Unreleased, issue #15)
- Date: 2026-10-11
- Research: `docs/research/mullvad-ivpn-gap-2026-10.md` (Mullvad `export-settings` /
  `import-settings` / `reset-settings`)

## Context

Issue #15 asks to move settings to another Mac or back after a reinstall, and to reset them. A
settings file is the kind of thing people drop into Downloads, iCloud, a chat with support or a
friend. The subscription link is a key to the paid account (ADR 0022 warns before showing it as a
QR code), and own servers are share links with their uuid, password or private key. Both live in
the Keychain on purpose.

## Decision

- Settings › Дополнительно › «Перенос настроек»: «Сохранить в файл…», «Загрузить из файла…»,
  «Сбросить…» (`App/SettingsTransferSection.swift`; the logic in `App/Core/SettingsBackup.swift`).
- **The file never has secrets, and there is no opt-in to add them.** Not in it: the subscription
  and backup links, own servers, anything in the Keychain. On a new Mac they are added again by
  pasting the link or scanning its QR code (ADR 0022), which takes seconds; a checkbox would make
  the one dangerous file a click away, and every later copy of it would be a leak nobody notices.
- Also left out: server identities (`id:type|host|port|hash`: a hash of the server's secret and its
  address, ServerIdentity) — favourites and recents are written by the servers' current names and
  become identities again on the next profile load; per-server transport overrides and «Двойной
  VPN» (both name servers of one subscription and mean nothing with another).
- In the file (JSON, `format: killswitch-settings`, `version: 1`): a fixed list of app settings
  (auto-connect, trusted networks, «Сети Wi‑Fi», notifications, menu bar speed, pause lengths,
  subscription interval, start without window, server order, profile groups, favourites, recents,
  beta updates) and the root ones as Settings shows them: the way of connecting, the switches
  (`lan`, `dns`, `tailscale`, `wifiguard`, `direct`, `adblock`, `diag`; since 0.20 `blockadult`, `blocksocial`,
  `blockbetting`), «Адреса без VPN», «Адреса серверов для других VPN-программ», «Программы без VPN»,
  «Свой сервер DNS-over-HTTPS» (`doh`, ADR 0031). Wi-Fi names are in it: the
  person exports their own file, and the screen says what is and is not inside.
- **Import checks the whole file first** (format, version — a newer one is refused with «обнови
  программу», types, the same ranges and validators as Settings and the daemon: `Batch.address`,
  `HelperCommand.isAddress`, `HelperCommand.setSplitApps(_).isValid`, `isName`). One bad value
  refuses the file and nothing changes. Unknown keys are ignored; keys the file does not name stay
  as they are. Then a sheet lists every change (old → new), root ones under «спросит пароль».
- **No new root write path.** App settings are written to UserDefaults and the live objects re-read
  them (`AutoConnector.reloadSettings`, `VPNClient.intervalHours`, `Updater.betaUpdates`,
  `syncSpeed`). Root settings become the commands their own screens run (`ks set`, `allow` /
  `unallow`, `server-add` / `server-remove`, `set splitapps`, through `Batch`), one batch through
  `runAsAdmin` — the daemon's authorization right or the admin prompt, after AdminGate. The way of
  connecting goes last through `VPNClient.switchCore`, which imports the subscription for it. Helper/ks
  is unchanged.
- **Reset** is the same sheet with the defaults: every app setting to its default, the switches to
  ks's defaults (`lan`, `tailscale`, `wifiguard` on; the rest off), the three lists emptied. The way
  of connecting stays (changing it re-imports the subscription; it has its own control). `ks repair`
  is not used: it only rewrites damaged files (#17) and leaves good settings alone.

## Consequences

- A file can be posted anywhere without exposing the VPN account; moving to a new Mac takes one
  extra step (add the subscription).
- A file with root settings asks for the password once when they differ; on a Mac without the
  service only the app settings apply, and the sheet says so.
- A new setting is not exported until it is added to `SettingsBackup.fields` (or `Root`);
  `version` goes up only when an old KillSwitch would misread a new file.
