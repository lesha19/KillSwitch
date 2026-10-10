# ADR 0019: mihomo without HTTP sniffing, process lookups or a way back into its own TUN

- Status: accepted (Unreleased); amends ADR 0013 (items 5 and 7)
- Date: 2026-10-10

## Context

Measured on the owner's Mac (system logs, 2026-10-10): 10–15% of TCP connections inside our
mihomo tunnel never got a byte back, while Happ (Xray) to the same server lost 0.6%. Of
connections to port 80, 52% failed. The generated config sniffed plain HTTP (80, 8080–8880) and
connections to bare addresses (`parse-pure-ip`, also mihomo's own default when a sniffer leaves
it out), looked up the program of every connection (`find-process-mode: always`), and the core
was seen sending its own connections back into its TUN (58 times). mihomo stays as the fallback
core (ADR 0020), so these are fixed in its config.

## Decision

- **Sniffer:** never HTTP, never bare addresses. The default sniffer is TLS 443/8443 and QUIC 443,
  `override-destination: false`. A subscription's sniffer is still taken key by key (ADR 0013),
  but `sniff.HTTP` and a true `parse-pure-ip` are left out with the reason «Это KillSwitch задаёт
  сам», and `parse-pure-ip: false` is always written.
- **`find-process-mode: strict`:** mihomo looks the program up only when a rule needs it
  («Программы без VPN»). The «Трафик» window shows the program when it is known.
- **Loop guard:** the first rule is `IP-CIDR,198.18.0.0/16,REJECT,no-resolve`, listed in the
  report as «Защита от петли». mihomo turns a known fake-ip back into its name before the rules
  (the address is cleared, so `no-resolve` keeps this rule off it) and refuses an unknown one
  itself; what this rule catches is a connection to a literal 198.18 address (the TUN's own
  gateway, another tunnel's address) that a DIRECT rule would send straight back into our TUN.
  REJECT is not a DIRECT target: the approval signature and pf are unchanged.

## Consequences

- Rules by domain for plain-HTTP sites and for programs that connect to bare addresses fall back
  to the address (GEOIP/IP-CIDR rules of the subscription, then the final rule).
- The connections list loses the program name for most connections.
- The cause of the lost connections and of the 58 loops is not proven: these remove the suspects
  named in the diagnosis (the fake-ip behaviour above is from mihomo's source as remembered, not
  re-read for 1.19.32); the live comparison with Happ has to be repeated on the owner's Mac.
