# ADR 0022: QR codes are read from pictures, not from the screen

- Status: accepted (Unreleased, issue #24)
- Date: 2026-10-11
- Research: `docs/research/incy-2026-10.md` (idea 3: QR scan and QR export)

## Context

Issue #24 asks to add a subscription or a server from a QR code on the screen or in a clipboard
image, and to show the person's own subscription as a QR code to move it to a phone.

Reading the screen directly (ScreenCaptureKit `SCScreenshotManager`, or `CGWindowListCreateImage`)
needs the Screen Recording permission. For KillSwitch that is a bad trade:

- the app already asks for an admin password, a privileged daemon and a content filter; a
  permission to see everything on the screen, for a feature used once per device, makes it look
  far more invasive than it is;
- the grant stays after the scan; macOS 15 reminds the person periodically that the app "can
  access your screen", and a VPN app that keeps that permission is a reasonable thing to distrust;
- the system already does the hard part: ⌃⇧⌘4 lets the person select a region and puts it on the
  clipboard, with no permission for any app.

## Decision

- «Сканировать QR…» (Settings › VPN, in «Подписка» when there is no link yet and in «Свои
  серверы») reads a picture from the clipboard, from a file (`fileImporter`, images only), or
  dropped on the sheet (file URLs only, so nothing is downloaded). The hint tells the person to
  press ⌃⇧⌘4. No screen capture API is used and no Screen Recording permission is asked.
- Codes are found with Vision (`VNDetectBarcodesRequest`, symbology QR) in memory
  (`App/Core/QRCode.swift`). The picture is neither kept nor written anywhere.
- `QRPayload.classify` only routes the text: `http(s)://` and an https link inside another
  client's import link (`clash://install-config?url=`, `sing-box://import-remote-profile?url=`,
  `happ://add/https://…`) go to `VPNClient.setURL`; share links of the schemes `ProxyLink` reads and
  wg-quick text go to `VPNClient.addLink`. Both check it as if typed; nothing is added on the scan
  alone: the sheet shows what was found (a subscription masked, servers as a count) and waits for
  «Добавить» / «Заменить подписку».
- «QR-код…» next to the subscription link shows its QR code only after a warning that the link is
  a key to the subscription. The code is drawn in memory (`CIQRCodeGenerator`, `CIContext` without
  intermediate caching), released when the sheet closes, and never logged. When the subscription
  answers with `hide-url: 1|true|yes` (INCY's header, read once into `ProviderInfo`, #26), the
  button is disabled.

## Consequences

- One extra keystroke for the person compared with a "scan the screen" button; no new permission,
  no entitlement, no Info.plist usage string.
- Encrypted import links (`happ://crypt…`) and other apps' private formats are not recognised; the
  sheet says the code has no subscription or server link.
- If screen scanning is wanted later, it is a new source of the same picture: `QRCode.payloads`
  and `QRPayload` stay as they are.
