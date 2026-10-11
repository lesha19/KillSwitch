#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# Own addresses of sites (#28, ADR 0033): "name=IPv4" pairs the core's DNS answers, for both cores.
# They change only which address a name gets: never the DIRECT signature, egress or pf, never our
# own listeners, the VPN's servers or the hosts KillSwitch itself needs. No root, no network.
#   Helper/tests/hosts.sh   (MIHOMO=…, XRAY=… to check the configs with the cores)
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
MIHOMO=${MIHOMO:-/Library/KillSwitch/core/mihomo}; [ -x "$MIHOMO" ] || [ ! -x "$here/../mihomo" ] || MIHOMO="$here/../mihomo"
XRAY=${XRAY:-/Library/KillSwitch/core/xray}; [ -x "$XRAY" ] || [ ! -x "$here/../xray" ] || XRAY="$here/../xray"
fx="$here/fixtures"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/home"
SETTINGS="$tmp/settings"
CORE_DIR="$tmp/core"; mkdir "$CORE_DIR"
APPROVED_HOSTS="$CORE_DIR/approved-hosts"; PINS="$CORE_DIR/pins"
resolve_host() { case "$1" in de.example.com) echo 203.0.113.20 ;; fi.example.com) echo 203.0.113.30 ;; *) return 1 ;; esac; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
put() { { grep -v "^$1=" "$SETTINGS" 2>/dev/null; echo "$1=$2"; } > "$SETTINGS.new"; mv "$SETTINGS.new" "$SETTINGS"; }
j() { /usr/bin/perl -MJSON::PP -e 'local $/; my $c = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "${2:-$tmp/c}"; }
q() { j "$1" "$tmp/c.report"; }
mt() {
  [ -x "$MIHOMO" ] || { echo "skip  $1: mihomo -t"; return; }
  local out
  if out=$("$MIHOMO" -t -d "$tmp/home" -f "$2" 2>&1); then ok "$1: mihomo -t"; else bad "$1: mihomo -t: $(tail -2 <<<"$out")"; fi
}
xtest() {
  [ -x "$XRAY" ] || { echo "skip  $1: xray run -test"; return; }
  local out
  if out=$(XRAY_LOCATION_ASSET=$(dirname "$XRAY") "$XRAY" run -test -format json -c "$2" 2>&1); then ok "$1: xray run -test"
  else bad "$1: xray run -test: $(tail -2 <<<"$out")"; fi
}
genm() { core_generate "$1" "$tmp/c" "$tmp/s" 2>"$tmp/err"; }
genx() { core_generate_xray "$1" "$tmp/c" "$tmp/s" 2>"$tmp/err"; }

# --- the list: exact public-looking names, IPv4 only, nothing of ours
[ "$(hosts_parse 'NAS.Home.Arpa=192.168.1.10,printer.lan=10.0.0.5,dns.example.com=203.0.113.53' | paste -sd' ' -)" = \
  "nas.home.arpa=192.168.1.10 printer.lan=10.0.0.5 dns.example.com=203.0.113.53" ] &&
  ok "parse: names lower-cased, home and public addresses taken" || bad "parse: $(hosts_parse 'NAS.Home.Arpa=192.168.1.10,printer.lan=10.0.0.5,dns.example.com=203.0.113.53' 2>&1)"
[ -z "$(hosts_parse '')" ] && ok "parse: empty list" || bad "parse empty"
hosts_parse 'tailnet.example=100.101.102.103' >/dev/null && ok "parse: a Tailscale address" || bad "parse: tailscale refused"
long=$(for i in $(seq 51); do printf 'h%s.example.com=203.0.113.1,' "$i"; done)
for e in nas=192.168.1.10 '*.example.com=203.0.113.1' '+.example.com=203.0.113.1' example.com=2001:db8::1 \
         example.com=127.0.0.1 example.com=0.0.0.0 example.com=198.18.0.5 example.com=198.19.1.1 example.com=224.0.0.1 \
         example.com=255.255.255.255 example.com=169.254.1.1 example.com=256.1.1.1 example.com=010.1.1.1 example.com= \
         =203.0.113.1 example.com 'example.com=203.0.113.1=x' 'exa mple.com=203.0.113.1' example.local=192.168.1.2 \
         localhost=127.0.0.1 x.localhost=192.168.1.2 -bad.example.com=203.0.113.1 example.123=203.0.113.1 \
         github.com=203.0.113.1 api.github.com=203.0.113.1 objects.githubusercontent.com=203.0.113.1 \
         cp.cloudflare.com=203.0.113.1 api.ipify.org=203.0.113.1 ipv4.am.i.mullvad.net=203.0.113.1 x.bash.ws=203.0.113.1 \
         'a.example.com=203.0.113.1,A.example.com=203.0.113.2' "$long" "$(printf 'a%.0s' $(seq 250)).com=203.0.113.1"; do
  hosts_parse "$e" >/dev/null 2>&1 && bad "parse: took ${e:0:60}" || ok "parse: refuses ${e:0:60}"
done
hosts_parse 'github.com=203.0.113.1' 2>&1 >/dev/null | grep -q github.com && ok "parse: says which entry" || bad "parse: no reason"

# --- the settings file (fail closed on anything else, ADR 0015)
lines_ok() { printf '%s\n' "$1" > "$tmp/lines"; settings_lines_ok "$tmp/lines"; }
lines_ok "hosts=" && lines_ok "hosts=nas.lan=192.168.1.10,dns.example.com=203.0.113.53" && ok "settings: hosts lines ks writes" || bad "settings: hosts refused"
lines_ok "hosts=nas=192.168.1.10" && bad "settings: took a bad hosts line" || ok "settings: refuses a hosts line ks would not write"

# --- ks set hosts: checked, never a name of the VPN's servers, "" clears, the config rebuilt
applied=0; core_apply_settings() { applied=$((applied + 1)); }
printf 'de.example.com\n' > "$APPROVED_HOSTS"; printf 'fi.example.com\t203.0.113.30\n' > "$PINS"
printf 'lan=1\n' > "$SETTINGS"
set_hosts 'Nas.lan=192.168.1.10,dns.example.com=203.0.113.53' && [ "$(setting hosts "")" = "nas.lan=192.168.1.10,dns.example.com=203.0.113.53" ] &&
  [ "$applied" = 1 ] && ok "set hosts: written lower-cased, the config rebuilt" || bad "set hosts: $(cat "$SETTINGS") $applied"
for e in de.example.com=203.0.113.1 fi.example.com=203.0.113.1 nas=1.2.3.4; do
  set_hosts "$e" 2>"$tmp/err" && bad "set hosts: took $e" ||
    { [ "$(setting hosts "")" = "nas.lan=192.168.1.10,dns.example.com=203.0.113.53" ] && [ -s "$tmp/err" ] && ok "set hosts: refuses $e, nothing changed" ||
      bad "set hosts $e: $(cat "$SETTINGS")"; }
done
set_hosts "" && ! grep -q '^hosts' "$SETTINGS" && grep -qx lan=1 "$SETTINGS" && [ "$applied" = 2 ] && ok "set hosts \"\": the line gone" ||
  bad "set hosts clear: $(cat "$SETTINGS")"
rm -f "$SETTINGS" "$APPROVED_HOSTS" "$PINS"
unset -f core_apply_settings

# --- mihomo: the core's own hosts table, nothing else changes
genm "$fx/ok-full.json"; cp "$tmp/c.direct" "$tmp/plain.direct"; cp "$tmp/c.egress" "$tmp/plain.egress"; j '$c->{rules}' > "$tmp/plain.rules"
put hosts "nas.lan=192.168.1.10,dns.example.com=203.0.113.53,de.example.com=203.0.113.99"
genm "$fx/ok-full.json" || bad "mihomo hosts refused: $(cat "$tmp/err")"
[ "$(j '$c->{hosts}')" = '{"dns.example.com":"203.0.113.53","nas.lan":"192.168.1.10"}' ] &&
  ok "mihomo: the list as hosts, a name of the VPN's servers left out" || bad "mihomo hosts: $(j '$c->{hosts}')"
[ "$(j '$c->{dns}{"use-hosts"} ? "yes" : "no"')" = yes ] && ok "mihomo: the DNS answers from it" || bad "mihomo use-hosts: $(j '$c->{dns}')"
[ "$(j '$c->{proxies}[1]{server}')" = 203.0.113.20 ] && ok "mihomo: the server stays pinned to its own address" || bad "mihomo pin: $(j '$c->{proxies}[1]')"
cmp -s "$tmp/c.direct" "$tmp/plain.direct" && cmp -s "$tmp/c.egress" "$tmp/plain.egress" && [ "$(j '$c->{rules}')" = "$(cat "$tmp/plain.rules")" ] &&
  ok "mihomo: rules, DIRECT signature and egress as without it" || bad "mihomo hosts changed rules/direct/egress"
[ "$(q 'join ",", map { @{ $_->{items} } } grep { $_->{kind} eq "hosts" } @{ $c->{added} }')" = "nas.lan → 192.168.1.10,dns.example.com → 203.0.113.53" ] &&
  ok "mihomo report: the entries named as the person's choice" || bad "mihomo report: $(q '$c->{added}')"
mt "mihomo: hosts" "$tmp/c"
rm -f "$SETTINGS"
genm "$fx/ok-minimal.json"
[ -z "$(j '$c->{hosts}')" ] && ok "mihomo: no list, no hosts" || bad "mihomo none: $(j '$c->{hosts}')"

# --- Xray: dns.hosts as full: names, over the template's for the same name
genx "$fx/xray-panel.json"; cp "$tmp/c.direct" "$tmp/x.direct"; cp "$tmp/c.egress" "$tmp/x.egress"; j '$c->{routing}' > "$tmp/x.routing"
put hosts "nas.lan=192.168.1.10,dns.example.com=203.0.113.53"
/usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); $a->[0]{dns}{hosts} = { "dns.example.com" => "198.51.100.1", "keep.example" => "198.51.100.2" };
  print JSON::PP->new->encode($a)' < "$fx/xray-panel.json" > "$tmp/p.json"
genx "$tmp/p.json" || bad "xray hosts refused: $(cat "$tmp/err")"
[ "$(j '$c->{dns}{hosts}')" = '{"full:dns.example.com":"203.0.113.53","full:nas.lan":"192.168.1.10","keep.example":"198.51.100.2"}' ] &&
  ok "xray: the list as exact names, the template's own entry for the same name replaced, its others kept" || bad "xray hosts: $(j '$c->{dns}{hosts}')"
genx "$fx/xray-panel.json"
cmp -s "$tmp/c.direct" "$tmp/x.direct" && cmp -s "$tmp/c.egress" "$tmp/x.egress" && [ "$(j '$c->{routing}')" = "$(cat "$tmp/x.routing")" ] &&
  ok "xray: routing, DIRECT signature and egress as without it" || bad "xray hosts changed routing/direct/egress"
[ "$(q 'join ",", map { @{ $_->{items} } } grep { $_->{kind} eq "hosts" } @{ $c->{added} }')" = "nas.lan → 192.168.1.10,dns.example.com → 203.0.113.53" ] &&
  ok "xray report: the entries named" || bad "xray report: $(q '$c->{added}')"
xtest "xray: hosts" "$tmp/c"
/usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); $a->[0]{outbounds}[0]{settings}{vnext}[0]{address} = "lt.example.com";
  print JSON::PP->new->encode($a)' < "$fx/xray-panel.json" > "$tmp/p.json"
resolve_host() { case "$1" in lt.example.com) echo 203.0.113.40 ;; *) return 1 ;; esac; }
put hosts "lt.example.com=203.0.113.99,nas.lan=192.168.1.10"
genx "$tmp/p.json" || bad "xray pinned refused: $(cat "$tmp/err")"
[ "$(j '$c->{dns}{hosts}')" = '{"full:nas.lan":"192.168.1.10"}' ] && ok "xray: a name of the VPN's servers left out" || bad "xray pinned: $(j '$c->{dns}{hosts}')"
printf 'hosts=nas=192.168.1.10\n' > "$SETTINGS"   # never written by ks: rules() locks down, the generator ignores it
genx "$fx/xray-panel.json"
[ -z "$(j '$c->{dns}{hosts}')" ] && ok "xray: a bad list is ignored" || bad "xray bad list: $(j '$c->{dns}{hosts}')"
rm -f "$SETTINGS"

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
