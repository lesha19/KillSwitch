# ADR 0017: our DNS address never outlives the core

- Status: accepted (Unreleased)
- Date: 2026-10-10

## Context

Measured on the owner's Mac (system logs, 2026-10-10): after an uninstall
`Setup:/Network/Service/<Wi-Fi>/DNS` still held `127.0.0.1`, so nothing resolved without the
core. `dns_apply` records each physical service's DNS before pointing it at the core. When a key
was already `127.0.0.1` and `dns-state` had no original for it (state lost, an earlier boot, a
crash between writes), it recorded `${prev:-$cur}`, that is `127.0.0.1` itself, and
`dns_restore` later "restored" our own address. `dns_restore` also did nothing at all without a
`dns-state` file.

## Decision

- `dns_apply` never records `127.0.0.1` as an original. Without a known original it records
  "no manual DNS" (`!`, the key is removed) for a `Setup:` key and "no servers" (`-`) for a
  `State:` key (DHCP gives them again on the next lease; search domains stay).
- `dns_restore` first puts back the recorded originals (same boot only, as before), then always
  strips `127.0.0.1` from the `Setup:` and `State:` DNS of every physical service
  (`dns_strip`), with or without a state file: other servers in the list stay, an emptied
  `Setup:` key is removed, an emptied `State:` key loses only `ServerAddresses`.
- `uninstall.sh` gets this through `ks core off`, which it already runs.

## Consequences

- Someone who runs their own resolver on `127.0.0.1` (dnscrypt-proxy and the like) loses that
  setting when our core stops; KillSwitch already took that address over while running.
- An emptied `State:` key leaves that service without DNS servers until DHCP renews; that is
  still better than a resolver that is not there.
