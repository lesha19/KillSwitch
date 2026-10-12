# KillSwitch — glossary

Terms as the owner and the UI use them. Decisions live in `docs/adr/`, behaviour in `docs/ux/spec.md`.

- **VPN включён** (the VPN is on): from «Подключить» until an explicit «Отключить», whatever happens
  in between — connecting, reconnecting, a server switch, an update, a dead server. Not the same as
  *connected*: the VPN can be on and not connected. (ADR 0035)
- **Подключено** (connected): the VPN is on and the tunnel carries traffic.
- **Блокировка** (blocking): everything outside the tunnel is dropped, except what the user allowed
  (LAN, exceptions). Always while the VPN is on; also while it is off when «Защита» is on.
- **Защита** (protection): the user's switch for blocking while the VPN is off (Mullvad's
  «lockdown mode»). Off, paused or «выключено» → the internet goes direct after «Отключить».
- **Пауза** (pause): protection off until a time; same meaning as off while it lasts.
- **Другой VPN** (another VPN): a tunnel of another program (Happ, dropweb…); KillSwitch stands by
  next to it (ADR 0018).
