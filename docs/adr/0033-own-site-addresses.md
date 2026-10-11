# 0033. Own addresses of sites (hosts) inside the protected DNS

Status: accepted — decided by the agent, the owner may change it (#28, 2026-10-12).

## Context

#28: a small `domain → IP` table answered by the core's own DNS (the one the system asks on
127.0.0.1:53 while our VPN runs), never by the system resolver; for a home server or a service
the provider's DNS gets wrong. Not for a DoH server's bootstrap address (#28 asked for it): both
cores send the own DoH server's name to the VPN server as a domain, resolved at the VPN exit, and
`hosts` never applies to it (measured, review of #28). It must not open anything: no DIRECT
path, no pf address, nothing that breaks the VPN itself (ADR 0013, 0017, 0031).

## Decision

`ks set hosts <name=IPv4,...>` (`hosts=` in settings, "" clears, at most 50), behind the
administrator and the core lock like every setting the generator reads.

- **Names**: exact DNS names of two labels or more, lower-cased, the last label starting with a
  letter. No wildcards: mihomo (`+.`, `*.`) and Xray (`domain:`) match subdomains differently,
  and an exact name behaves the same in both. Not `.local` (mDNS never asks DNS), not `localhost`.
- **Addresses**: IPv4 only (IPv6 is blocked, ADR 0003; the core answers no AAAA), without leading
  zeros; never `0/8`, `127/8` (our listeners on 127.0.0.1:53 and :47890), `169.254/16`,
  `198.18/15` (our TUN and fake-ip range) or `224/4` and up. Home and Tailscale addresses are
  allowed: whether they are reachable is still pf's «Домашняя сеть» / Tailscale switch.
- **Never redirected**: the names KillSwitch itself needs, with their subdomains — `github.com`,
  `githubusercontent.com` (updates), `cp.cloudflare.com` (probes), `ipify.org`, `mullvad.net`,
  `bash.ws` (leak test); the VPN's servers (`ks set hosts` refuses names in `approved-hosts` and
  `pins`, and both generators leave such an entry out if the subscription gains that name later:
  servers stay pinned to the addresses the import approved); the subscription links' hosts (the
  app refuses them; ks does not know them).
- The same check in ks (`hosts_parse`, also for the settings file — a bad line blocks
  everything, ADR 0015) and in the app (`HelperCommand.isHostsEntry`).

Configs: mihomo top-level `hosts` with `dns.use-hosts: true` (answered before fake-ip, so the
program gets the real address); Xray `dns.hosts` with `full:<name>`. Xray answers with every
matching entry at once (measured, 26.9.30), so a template entry that also matches the name — `full:`,
plain, `domain:` (a leading dot ignored, as Xray does) or `keyword:`, compared lower-cased — is
left out and reported as `own-hosts`; the template's other entries stay. Such an entry goes as a
whole: a broad one (`domain:corp.example`, `keyword:ads`) then stops applying to every other name it
covered too, which get ordinary answers through the VPN — accepted, Xray has no way to except one
name from an entry. Every `regexp:` entry goes as soon as there is an own name (decided by agent,
re-review of #28): the alternative, running the subscription's pattern in Perl with a time limit
in a child process, is more code and still not Xray's dialect (RE2: linear, `(?U)`, an empty
pattern matches all), and Perl's backtracking let a crafted pattern hold the generator and the
core lock for minutes. `geosite:` and `ext:` entries are not looked into (accepted: a template that
maps a whole category to an address is unusual). Both are added after the DIRECT signature.

**What an answer changes**: only the address a program connects to. The rules decide where that
connection goes, exactly as for any address: through the VPN, or DIRECT only if the
subscription's rules (already approved by the admin and listed in egress) send that address or
name there. Except home and Tailscale addresses: mihomo's TUN leaves 10/8, 172.16/12, 192.168/16
and 100.64/10 out of its routes; Xray's TUN takes 0.0.0.0/0 and excludes nothing
(`autoSystemRoutingTable`), so there only what has a more specific route on the Mac (the home
network's own subnet, a route another tunnel added) skips it. Those go straight out, past the
core — allowed only by pf's «Доступ к домашней сети» / «Tailscale, NetBird» switches, and unseen by
category blocking. The table adds no rule, no pf address, nothing to the DIRECT signature or egress, so
`ks core refresh` asks nothing new. An address in the home network is reached only if pf allows
the home network. The report names each entry as the person's choice; events.log only the count. `ks set hosts`
puts the old list back when the core does not take the config, and builds the config again with
it when the new one was in place but the core was not reloaded.

## Consequences

- Settings › Дополнительно «Свои адреса сайтов», under «Свой сервер DNS-over-HTTPS»; a sheet with
  name and address fields. Settings transfer (ADR 0024) carries the list.
- Works only while our core runs (the answer comes from the core).
- Live check needed: a name from the table resolves to its address through 127.0.0.1:53 with
  both cores (mihomo fake-ip mode included), and a home address is reached with «Домашняя сеть».
