#!/bin/bash
# shellcheck disable=SC2034 # globals here are read by the sourced Helper/ks
# The Xray subscription is a second parser that root runs on what a panel sends (ADR 0020, #37):
# hostile and broken configs against its allow-list. Each case is the panel fixture with one
# change; it must be refused, or come out with nothing that sends traffic past the tunnel or the
# approval of servers (direct signature, servers for pf). Accepted configs also pass
# "xray run -test" when the binary is there. No root, no network.
#   Helper/tests/core-xray-fuzz.sh   (XRAY=/path/to/xray)
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../ks
. "$here/../ks"
XRAY=${XRAY:-/Library/KillSwitch/core/xray}; [ -x "$XRAY" ] || [ ! -x "$here/../xray" ] || XRAY="$here/../xray"
fx="$here/fixtures"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
SETTINGS="$tmp/settings"; : > "$SETTINGS"
EVENTS="$tmp/events.log"; DIAG="$tmp/none"
CORE_DIR="$tmp/core"; mkdir "$CORE_DIR"
resolve_host() { case "$1" in *.example.com) echo 203.0.113.40 ;; *) return 1 ;; esac; }
fails=0
ok()  { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }
# edit <perl over $c, the fixture's config (and $a, the array)>: the changed subscription in $tmp/p.json
# (~u017f~ in a string becomes the JSON escape \u017f; "\xc5\xbf" stays the raw UTF-8 bytes)
edit() { /usr/bin/perl -MJSON::PP -e 'local $/; my $a = JSON::PP->new->decode(<STDIN>); my $c = $a->[0]; eval $ARGV[0]; die $@ if $@;
           print JSON::PP->new->encode($a) =~ s/~u([0-9a-f]{4})~/\\u$1/gr' "$1" < "$fx/xray-panel.json" > "$tmp/p.json"; }
j() { /usr/bin/perl -MJSON::PP -e 'local $/; my $c = JSON::PP->new->decode(<STDIN>); my $v = eval $ARGV[0]; die $@ if $@;
        print ref $v ? JSON::PP->new->canonical->encode($v) : $v // ""' "$1" < "${2:-$tmp/c}"; }
gen() { core_generate_xray "$tmp/p.json" "$tmp/c" "$tmp/s" 2>"$tmp/err"; }
xtest() {  # xtest <name>: the generated config passes xray run -test
  [ -x "$XRAY" ] || return 0
  local out
  out=$(XRAY_LOCATION_ASSET=$(dirname "$XRAY") "$XRAY" run -test -format json -c "$tmp/c" 2>&1) || bad "$1: xray run -test: $(tail -1 <<<"$out" | head -c 300)"
}
refused() {  # refused <name> <perl edit> [what the message says]
  edit "$2"
  if gen; then bad "$1: accepted"
  elif [ -n "${3:-}" ] && ! grep -qF -- "$3" "$tmp/err"; then bad "$1: refused, but: $(head -c 300 "$tmp/err")"
  else ok "$1: refused"; fi
}
accepted() {  # accepted <name> <perl edit>: generated and passes xray run -test
  edit "$2"
  if gen; then xtest "$1"; return 0; fi
  bad "$1: refused: $(head -c 300 "$tmp/err")"; return 1
}
# perhost <name> <perl edit of $b, a host>: with that host alone the subscription is refused; next to
# the fixture's good host only it is left out, named in the report, nothing of it reaches pf
perhost() {
  edit 'my $b = $c; '"$2"
  if gen; then bad "$1: alone: accepted"
  elif ! grep -qF "ни одного годного" "$tmp/err"; then bad "$1: alone: refused, but: $(head -c 300 "$tmp/err")"
  else ok "$1: alone: refused"; fi
  edit 'my $b = JSON::PP->new->decode(JSON::PP->new->encode($c)); $b->{remarks} = "Плохой"; '"$2"'; push @$a, $b'
  if gen; then
    xtest "$1"
    [ "$(j 'join "|", map { $_->{name} } @{ $c->{servers} }' "$tmp/c.report")" = "🇱🇹Литва" ] &&
      [ "$(j 'join "|", map { "$_->{section}:$_->{item}" } grep { $_->{section} eq "servers" } @{ $c->{dropped} }' "$tmp/c.report")" = "servers:Плохой" ] &&
      [ "$(paste -sd' ' "$tmp/s")" = 203.0.113.10 ] && ok "$1: next to a good host: only it dropped, in the report" ||
      bad "$1: next to a good host: servers $(j '$c->{servers}' "$tmp/c.report") dropped $(j '$c->{dropped}' "$tmp/c.report") pf $(paste -sd' ' "$tmp/s")"
  else bad "$1: next to a good host: refused: $(head -c 300 "$tmp/err")"; fi
}
raw() {  # raw <name> <file content>: never accepted
  printf '%s' "$2" > "$tmp/p.json"
  if gen; then bad "raw $1: accepted"; else ok "raw $1: refused"; fi
}

# --- not an Xray subscription at all
raw empty ""
raw null null
raw object '{}'
raw "empty list" '[]'
raw "list of numbers" '[1,2]'
raw "outbounds not a list" '[{"outbounds":{}}]'
raw truncated '[{"outbounds":[]}'
raw yaml $'proxies:\n  - name: a\n    type: vless\n'
raw "mihomo JSON" '{"proxies":[{"name":"a","type":"vless","server":"1.2.3.4","port":443}]}'
raw "byte order mark" $'\xef\xbb\xbf[{"outbounds":[{"protocol":"vless","tag":"a","settings":{"vnext":[{"address":"1.2.3.4","port":443}]}}]}]'
deep=$(printf '{"a":%.0s' $(seq 1 600)); deep_end=$(printf '}%.0s' $(seq 1 600))
raw "nested 600 deep" "[{\"outbounds\":[{\"protocol\":\"vless\",\"tag\":\"a\",\"settings\":{\"vnext\":[{\"address\":\"1.2.3.4\",\"port\":443}]}}],\"policy\":${deep}1${deep_end}}]"
head -c 20000001 /dev/zero | tr '\0' ' ' > "$tmp/p.json"
gen && bad "more than 20 MB: accepted" || ok "more than 20 MB: refused"
refused "201 configs" '@$a = ($c) x 201' "Слишком много"

# --- the protocol allow-list (vless vmess trojan shadowsocks freedom blackhole dns loopback)
# (a host with another one is left out, the others stay: 0.19.1 review 2)
for p in wireguard socks http hysteria hysteria2 tuic VLESS " vless" "vless " "vless\n" ""; do
  perhost "protocol «${p}»" '$b->{outbounds}[0]{protocol} = "'"$p"'"'
done
perhost "protocol as a list" '$b->{outbounds}[0]{protocol} = ["vless"]'
perhost "protocol missing" 'delete $b->{outbounds}[0]{protocol}'
refused "an outbound that is a string" 'push @{$c->{outbounds}}, "freedom"' "не объект"
refused "two outbounds with one tag" 'push @{$c->{outbounds}}, { tag => "LT_1", protocol => "blackhole" }' "два outbound"
refused "no server at all" '@{$c->{outbounds}} = grep { $_->{protocol} !~ /vless/ } @{$c->{outbounds}}; delete $c->{routing}{balancers}' "нет ни одного сервера"

# --- server addresses: IPv4 or a host name we pin, nothing else (a host with another one is
# left out, the others stay: 0.19.1 review 2)
for h in "a b.example.com" "a.example.com;id" 'a.example.com$(id)' "a.example.com/x" "-a.example.com" "2001:db8::1" "::ffff:1.2.3.4" \
         "[2001:db8::1]" "env:HOME" "é.example.com" "١.٢.٣.٤" "1.2.3.٤"; do
  perhost "server address «${h}»" '$b->{outbounds}[0]{settings}{vnext}[0]{address} = "'"$h"'"'
done
# a name that does not resolve still refuses the subscription: on an import that may be a network
# hiccup, and a host left out at the import would come back with a refresh as a server nobody
# approved (a refresh that then asks for the password)
for h in localhost a..b; do
  refused "server address «${h}» (cannot be pinned)" '$c->{outbounds}[0]{settings}{vnext}[0]{address} = "'"$h"'"' "Не удалось узнать адрес"
done
# panels put placeholder hosts at 0.0.0.0 or 127.0.0.1 («подписка истекла», days left): such a
# host is dropped and named in the report, the others stay; refused only when none is left
for h in 0.0.0.0 127.0.0.1 224.0.0.1 255.255.255.255 999.1.1.1 1.2.3.256 01.2.3.4 0177.0.0.1 1.2.3 2130706433; do
  perhost "server address «${h}»" '$b->{outbounds}[0]{settings}{vnext}[0]{address} = "'"$h"'"'
done
refused "server address with a newline" '$c->{outbounds}[0]{settings}{vnext}[0]{address} = "a.example.com\nb"'
refused "server address a number" '$c->{outbounds}[0]{settings}{vnext}[0]{address} = 16909060'
perhost "server address a list" '$b->{outbounds}[0]{settings}{vnext}[0]{address} = ["1.2.3.4"]'
perhost "server address empty" '$b->{outbounds}[0]{settings}{vnext}[0]{address} = ""'
perhost "server address missing" 'delete $b->{outbounds}[0]{settings}{vnext}[0]{address}'
for v in "1e30" "-1" '"443-500"'; do
  edit '$c->{outbounds}[0]{settings}{vnext}[0]{port} = '"$v"
  if gen && [ -x "$XRAY" ] && XRAY_LOCATION_ASSET=$(dirname "$XRAY") "$XRAY" run -test -format json -c "$tmp/c" >/dev/null 2>&1; then
    bad "port $v: Xray takes it"
  else ok "port $v: never runs (refused here or by xray run -test before it is put in place)"; fi
done
# a second server in the same outbound (flat address next to vnext, servers in vless) is
# checked and approved like the first
if accepted "a second address in vless (servers)" 'push @{$c->{outbounds}[0]{settings}{servers}}, { address => "198.51.100.9", port => 443 }'; then
  grep -qx 198.51.100.9 "$tmp/s" && ok "  its address is a server for pf (approved with the import)" || bad "  servers: $(paste -sd' ' "$tmp/s")"
fi

# XHTTP can download from another server (downloadSettings, also inside "extra"): that address
# is a server too, pinned and approved like the others, never dialled by name
xh='$c->{outbounds}[0]{streamSettings} = { network => "xhttp", security => "tls", tlsSettings => { serverName => "a.example.com" },
      xhttpSettings => { path => "/x", mode => "auto", downloadSettings => { address => "dl.example.com", port => 443, network => "xhttp",
      security => "tls", xhttpSettings => { path => "/y" }, sockopt => { interface => "en0", mark => 7, customSockopt => [{ level => "0", opt => "25", value => "4" }] } } } }'
if accepted "XHTTP downloadSettings to another host" "$xh"; then
  [ "$(j '$c->{outbounds}[0]{streamSettings}{xhttpSettings}{downloadSettings}{address}')" = 203.0.113.40 ] &&
    [ "$(j '$c->{outbounds}[0]{streamSettings}{xhttpSettings}{downloadSettings}{tlsSettings}{serverName}')" = dl.example.com ] &&
    ok "  pinned to its approved address, the name kept for TLS" || bad "  download: $(j '$c->{outbounds}[0]{streamSettings}{xhttpSettings}{downloadSettings}')"
  grep -qx 203.0.113.40 "$tmp/s" && grep -q '^dl.example.com	203.0.113.40$' "$tmp/c.pins" && ok "  a server for pf, and among the pinned names refresh compares" ||
    bad "  servers: $(paste -sd' ' "$tmp/s") pins: $(cat "$tmp/c.pins")"
  [ "$(j 'join ",", sort keys %{ $c->{outbounds}[0]{streamSettings}{xhttpSettings}{downloadSettings}{sockopt} }')" = "" ] &&
    ok "  its socket bound to no interface or mark" || bad "  sockopt: $(j '$c->{outbounds}[0]{streamSettings}{xhttpSettings}{downloadSettings}{sockopt}')"
fi
if accepted "XHTTP downloadSettings inside extra" '$c->{outbounds}[0]{streamSettings} = { network => "xhttp", security => "tls",
      xhttpSettings => { path => "/x", extra => { downloadSettings => { address => "198.51.100.8", port => 443, network => "xhttp", xhttpSettings => { path => "/y" } } } } }'; then
  grep -qx 198.51.100.8 "$tmp/s" && ok "  its address is a server for pf too" || bad "  servers: $(paste -sd' ' "$tmp/s")"
fi
perhost "XHTTP download address not a server address" '$b->{outbounds}[0]{streamSettings} = { network => "xhttp",
      xhttpSettings => { downloadSettings => { address => "a.example.com;id", port => 443 } } }'
# the older name of XHTTP (splithttp, still read by Xray) the same way
if accepted "SplitHTTP downloadSettings" '$c->{outbounds}[0]{streamSettings} = { network => "splithttp", security => "tls",
      splithttpSettings => { path => "/x", downloadSettings => { address => "sh.example.com", port => 443, network => "splithttp", security => "tls",
      splithttpSettings => { path => "/y" } } } }'; then
  [ "$(j '$c->{outbounds}[0]{streamSettings}{splithttpSettings}{downloadSettings}{address}')" = 203.0.113.40 ] && grep -qx 203.0.113.40 "$tmp/s" &&
    grep -q '^sh.example.com	' "$tmp/c.pins" && ok "  pinned and approved" || bad "  splithttp: $(j '$c->{outbounds}[0]{streamSettings}')"
fi
if accepted "SplitHTTP downloadSettings inside extra" '$c->{outbounds}[0]{streamSettings} = { network => "splithttp",
      splithttpSettings => { extra => { downloadSettings => { address => "198.51.100.6", port => 443 } } } }'; then
  grep -qx 198.51.100.6 "$tmp/s" && ok "  its address is a server for pf too" || bad "  servers: $(paste -sd' ' "$tmp/s")"
fi
# a download inside the download, or an address anywhere else in the stream settings: nothing
# would pin it, the host is dropped
perhost "downloadSettings inside downloadSettings" '$b->{outbounds}[0]{streamSettings} = { network => "xhttp", xhttpSettings => { downloadSettings => {
      address => "198.51.100.8", port => 443, xhttpSettings => { downloadSettings => { address => "evil.example.com", port => 443 } } } } }'
perhost "downloadSettings inside extra inside downloadSettings" '$b->{outbounds}[0]{streamSettings} = { network => "xhttp", xhttpSettings => { downloadSettings => {
      address => "198.51.100.8", port => 443, xhttpSettings => { extra => { downloadSettings => { address => "evil.example.com", port => 443 } } } } } }'
perhost "an address elsewhere in the stream settings" '$b->{outbounds}[0]{streamSettings}{wsSettings} = { future => { address => "evil.example.com" } }'
refused "XHTTP download through a missing outbound" '$c->{outbounds}[0]{streamSettings} = { network => "xhttp",
      xhttpSettings => { downloadSettings => { address => "198.51.100.8", port => 443, sockopt => { dialerProxy => "nope" } } } }' "несуществующий"

# --- a rebuild from the kept pins (rotation, settings, ks _regen, a passwordless switch): a host
# whose XHTTP download goes to a name without a pin (0.19.0 did not pin those) is left out, the
# others still build; the next import with the password pins and approves it (0.19.1 review 2)
edit 'my $b = JSON::PP->new->decode(JSON::PP->new->encode($c)); $b->{remarks} = "Плохой";
      $b->{outbounds}[0]{streamSettings} = { network => "xhttp", security => "tls", xhttpSettings => { path => "/x",
        downloadSettings => { address => "dl.example.com", port => 443, network => "xhttp", security => "tls", xhttpSettings => { path => "/y" } } } };
      push @$a, $b'
: > "$tmp/pins0"
if KS_PINS="$tmp/pins0" gen; then
  xtest "unpinned download on a rebuild"
  [ "$(j 'join "|", map { $_->{name} } @{ $c->{servers} }' "$tmp/c.report")" = "🇱🇹Литва" ] &&
    [ "$(j 'join "|", map { "$_->{item}:$_->{reason}" } grep { $_->{section} eq "servers" } @{ $c->{dropped} }' "$tmp/c.report")" = "Плохой:download" ] &&
    [ "$(paste -sd' ' "$tmp/s")" = 203.0.113.10 ] && [ ! -s "$tmp/c.pins" ] &&
    ok "a rebuild with a download name not pinned: that host left out (download), the other runs" ||
    bad "unpinned download on a rebuild: servers $(j '$c->{servers}' "$tmp/c.report") dropped $(j '$c->{dropped}' "$tmp/c.report") pf $(paste -sd' ' "$tmp/s")"
else bad "a rebuild with a download name not pinned: refused: $(cat "$tmp/err")"; fi
printf 'dl.example.com\t203.0.113.40\n' > "$tmp/pins1"
if KS_PINS="$tmp/pins1" gen && [ "$(j 'join "|", map { $_->{name} } @{ $c->{servers} }' "$tmp/c.report")" = "🇱🇹Литва|Плохой" ]; then
  ok "  pinned (after an import): both hosts"
else bad "  pinned: servers $(j '$c->{servers}' "$tmp/c.report") $(cat "$tmp/err")"; fi
if gen && [ "$(j 'join "|", map { $_->{name} } @{ $c->{servers} }' "$tmp/c.report")" = "🇱🇹Литва|Плохой" ] && grep -q '^dl.example.com	' "$tmp/c.pins"; then
  ok "  an import: resolved, pinned, both hosts"
else bad "  import: servers $(j '$c->{servers}' "$tmp/c.report") $(cat "$tmp/err")"; fi

# --- what Xray reads as unset is not a server or a chain (0.19.1 review): an empty fallbackTag
# (no fallback), an empty dialerProxy (no chain), a download address null or "" (the outbound's own)
if accepted "balancer fallbackTag empty (no fallback)" '$c->{routing}{balancers}[0]{fallbackTag} = ""'; then
  [ "$(j 'join "|", map { $_->{name} } @{ $c->{servers} }' "$tmp/c.report")" = "🇱🇹Литва" ] && ok "  the host kept" || bad "  servers: $(j '$c->{servers}' "$tmp/c.report")"
fi
accepted "download dialerProxy empty (no chain)" '$c->{outbounds}[0]{streamSettings} = { network => "xhttp", xhttpSettings => { path => "/x",
      downloadSettings => { address => "198.51.100.8", port => 443, network => "xhttp", sockopt => { dialerProxy => "" }, xhttpSettings => { path => "/y" } } } }' &&
  ok "  accepted"
# an empty dialerProxy is no chain for the latency probe either: the host keeps its ks-ping
for v in undef '""'; do
  if accepted "dialerProxy $v on the server's own stream" '$c->{outbounds}[0]{streamSettings}{sockopt}{dialerProxy} = '"$v"; then
    [ "$(j '$c->{servers}[0]{ping} // ""' "$tmp/c.report")" = ks-ping-0 ] && ok "  probed as ks-ping-0" || bad "  servers: $(j '$c->{servers}' "$tmp/c.report")"
  fi
done
for v in undef '""'; do
  if accepted "download address $v (the outbound's own)" '$c->{outbounds}[0]{streamSettings} = { network => "xhttp", xhttpSettings => { path => "/x",
        downloadSettings => { address => '"$v"', port => 443, network => "xhttp", xhttpSettings => { path => "/y" } } } }'; then
    [ "$(paste -sd' ' "$tmp/s")" = 203.0.113.10 ] && ok "  no server of its own for pf" || bad "  servers: $(paste -sd' ' "$tmp/s")"
  fi
done

# --- a name pinned to an address keeps the HTTP Host it gave (0.19.1 review): without TLS the
# transports send the address as Host, and a reverse proxy routing by name would get the IP
if accepted "plaintext XHTTP download by name" '$c->{outbounds}[0]{streamSettings} = { network => "xhttp", xhttpSettings => { path => "/x",
      downloadSettings => { address => "dl.example.com", port => 80, network => "xhttp", xhttpSettings => { path => "/y" } } } }'; then
  [ "$(j '$c->{outbounds}[0]{streamSettings}{xhttpSettings}{downloadSettings}{xhttpSettings}{host}')" = dl.example.com ] &&
    ok "  its xhttpSettings.host is the name" || bad "  download: $(j '$c->{outbounds}[0]{streamSettings}{xhttpSettings}{downloadSettings}')"
fi
for n in ws:wsSettings httpupgrade:httpupgradeSettings xhttp:xhttpSettings splithttp:splithttpSettings; do
  if accepted "plaintext ${n%%:*} by name" '$c->{outbounds}[0]{settings}{vnext}[0]{address} = "a.example.com";
        $c->{outbounds}[0]{streamSettings} = { network => "'"${n%%:*}"'", security => "none", '"${n#*:}"' => { path => "/p" } }'; then
    [ "$(j '$c->{outbounds}[0]{settings}{vnext}[0]{address}')" = 203.0.113.40 ] && [ "$(j '$c->{outbounds}[0]{streamSettings}{'"${n#*:}"'}{host}')" = a.example.com ] &&
      ok "  pinned, ${n#*:}.host the name" || bad "  stream: $(j '$c->{outbounds}[0]{streamSettings}')"
  fi
done
if accepted "a Host of its own is kept" '$c->{outbounds}[0]{settings}{vnext}[0]{address} = "a.example.com";
      $c->{outbounds}[0]{streamSettings} = { network => "ws", wsSettings => { path => "/p", host => "cdn.example.net" } }'; then
  [ "$(j '$c->{outbounds}[0]{streamSettings}{wsSettings}{host}')" = cdn.example.net ] && ok "  unchanged" || bad "  ws: $(j '$c->{outbounds}[0]{streamSettings}')"
fi
if accepted "a ws Host header of its own is kept" '$c->{outbounds}[0]{settings}{vnext}[0]{address} = "a.example.com";
      $c->{outbounds}[0]{streamSettings} = { network => "ws", wsSettings => { path => "/p", headers => { Host => "cdn.example.net" } } }'; then
  [ "$(j 'exists $c->{outbounds}[0]{streamSettings}{wsSettings}{host} ? "added" : "none"')" = none ] && ok "  no host added next to it" || bad "  ws: $(j '$c->{outbounds}[0]{streamSettings}')"
fi

# reading the transports adds nothing to them
if accepted "a ws stream read as it is" '$c->{outbounds}[0]{streamSettings} = { network => "ws", security => "tls", wsSettings => { path => "/p" } }'; then
  [ "$(j 'join ",", sort keys %{ $c->{outbounds}[0]{streamSettings} }')" = network,security,wsSettings ] && ok "  no xhttpSettings or splithttpSettings added" ||
    bad "  stream: $(j '$c->{outbounds}[0]{streamSettings}')"
fi

# --- the direct signature of a subscription that 0.19.0 approved is the same now: a different one
# would make every passwordless switch after the upgrade ask for the password
# (0.19.1 review: reading the transports once added keys to every stream). The 0.19.0 hashes:
for g in "xray-panel.json 5c3272a3902c1cee70f8f54e9bda93e469f103f69cc053b446f88a544c441599" \
         "xray-3xui.json b05acca29ee7282b849360f55dea7bd65ad8937af75ef75d3b71fee028d541a9"; do
  cp "$fx/${g%% *}" "$tmp/p.json"
  if KS_APPROVE_ALL=1 gen; then
    [ "$(shasum -a 256 < "$tmp/c.direct" | cut -c1-64)" = "${g#* }" ] && [ "$(cat "$tmp/c.approved")" = "${g#* }" ] &&
      ok "${g%% *}: the direct signature 0.19.0 approved" || bad "${g%% *}: direct signature $(shasum -a 256 < "$tmp/c.direct") $(cat "$tmp/c.direct")"
    xtest "${g%% *}"
    grep -q ':null' "$tmp/c" && bad "${g%% *}: a key read as null added to the config" || ok "  no key read into existence (null) in the config"
  else bad "${g%% *}: refused: $(cat "$tmp/err")"; fi
done

# --- Xray reads keys in any case (Go's JSON) and a selector as one string: «Selector»,
# «fallbacktag», «Address» would pass a check that reads the exact spelling (0.19.1 review)
perhost "balancer «Selector» to the freedom outbound" 'delete $b->{routing}{balancers}[0]{selector}; $b->{routing}{balancers}[0]{Selector} = ["direct"]'
perhost "balancer selector as one string" '$b->{routing}{balancers}[0]{selector} = "direct"'
perhost "balancer «fallbacktag»" '$b->{routing}{balancers}[0]{fallbacktag} = "direct"'
perhost "observatory selector as one string" '$b->{burstObservatory}{subjectSelector} = "direct"'
perhost "XHTTP «downloadsettings» with «Address»" '$b->{outbounds}[0]{streamSettings} = { network => "xhttp", xhttpSettings => { path => "/x",
      downloadsettings => { Address => "evil.example.com", port => 443 } } }'
perhost "vless flat settings «Address»" 'delete $b->{outbounds}[0]{settings}{vnext}; $b->{outbounds}[0]{settings}{Address} = "evil.example.com";
      $b->{outbounds}[0]{settings}{port} = 443; $b->{outbounds}[0]{settings}{id} = "00000000-0000-4000-8000-000000000001"'
perhost "a DNS server «Address»" 'push @{$b->{dns}{servers}}, { Address => "tcp+local://9.9.9.9" }'
perhost "«TAG» next to tag" '$b->{outbounds}[2]{TAG} = "LT_9"'
perhost "«sockopt» spelled «SockOpt» with an interface" '$b->{outbounds}[0]{streamSettings}{SockOpt} = { interface => "en0" }'
# only the keys the checks read: Xray's own spellings of the others are the subscription's
# (0.19.1 review, second round: observatory.probeURL, accepted by 0.19.0, was refused)
if accepted "an observatory with probeURL, Xray's spelling" 'delete $c->{burstObservatory};
      $c->{observatory} = { subjectSelector => ["LT_"], probeURL => "https://www.google.com/generate_204", probeInterval => "30s", enableConcurrency => JSON::PP::true }'; then
  [ "$(j '$c->{observatory}{probeURL}')" = https://www.google.com/generate_204 ] && ok "  taken as it is" || bad "  observatory: $(j '$c->{observatory}')"
fi
accepted "keys the checks do not read, in any case" '$c->{dns}{servers}[1]{QueryStrategy} = "UseIPv4"; delete $c->{dns}{servers}[1]{queryStrategy};
      $c->{dns}{QueryStrategy} = delete $c->{dns}{queryStrategy} // "UseIPv4";
      $c->{outbounds}[2]{settings}{DomainStrategy} = delete $c->{outbounds}[2]{settings}{domainStrategy} // "UseIPv4";
      $c->{routing}{balancers}[0]{Strategy} = { type => "random" }; delete $c->{routing}{balancers}[0]{strategy}' && ok "  taken"
if accepted "a ws Host header in any case is the subscription's own" '$c->{outbounds}[0]{streamSettings} = { network => "ws", security => "tls",
      wsSettings => { path => "/p", headers => { HOST => "a.example.com", "User-Agent" => "x" } } }'; then
  ok "  taken (header names are not Xray's keys)"
fi

# --- Go folds more than ASCII case: «ſ» (U+017F) reads as s and «K» (U+212A, Kelvin) as k, raw
# or escaped, so «ſelector» is a balancer's selector to Xray and nothing to the checks here; it
# sorts after «selector» and Xray applies it last (0.19.1 review, second round)
for u in 'raw:\xc5\xbf:\xe2\x84\xaa' 'escaped:~u017f~:~u212a~'; do
  IFS=: read -r form s k <<<"$u"
  perhost "$form ſ: balancer «ſelector» to the freedom outbound" '$b->{routing}{balancers}[0]{"'"$s"'elector"} = ["LT_", "direct"]'
  perhost "$form K: balancer «fallbacKTag»" '$b->{routing}{balancers}[0]{"fallbac'"$k"'Tag"} = "direct"'
  perhost "$form ſ: burstObservatory «subjectſelector»" '$b->{burstObservatory}{"subject'"$s"'elector"} = ["dir"]'
  perhost "$form ſ: vnext «addreſs»" '$b->{outbounds}[0]{settings}{vnext}[0]{"addre'"$s"'s"} = "evil.example.com"'
  perhost "$form ſ: a DNS server «addreſs» +local" 'push @{$b->{dns}{servers}}, { "addre'"$s"'s" => "tcp+local://9.9.9.9" }'
  perhost "$form ſ: outbound settings «reverſe»" '$b->{outbounds}[0]{settings}{"rever'"$s"'e"} = { tag => "r" }'
  perhost "$form ſ: «ſockopt» with an interface" '$b->{outbounds}[0]{streamSettings}{"'"$s"'ockopt"} = { interface => "en0", mark => 7 }'
  perhost "$form K: «socKopt» with an interface" '$b->{outbounds}[0]{streamSettings}{"soc'"$k"'opt"} = { interface => "en0" }'
  perhost "$form ſ: «ſendThrough»" '$b->{outbounds}[0]{"'"$s"'endThrough"} = "192.168.1.5"'
  perhost "$form ſ: «ſettings» of the DNS outbound" '$b->{outbounds}[4]{"'"$s"'ettings"} = { address => "1.1.1.1", port => 53 }'
  perhost "$form ſ: «streamſettings»" '$b->{outbounds}[0]{"stream'"$s"'ettings"} = { sockopt => { interface => "en0" } }'
done
# header names, DNS hosts and rule attributes are data: any letters there are the subscription's
if accepted "non-ASCII header names, DNS hosts and rule attributes" '$c->{outbounds}[0]{streamSettings} = { network => "ws", security => "tls",
      wsSettings => { path => "/p", headers => { "X-\xc5\xbf" => "x", "X-~u212a~" => "y" } } };
      $c->{dns}{hosts} = { "domain:\xd0\xbf\xd1\x80\xd0\xb8.example.com" => "198.51.100.3" };
      unshift @{$c->{routing}{rules}}, { attrs => { ":\xc5\xbf" => "x" }, outboundTag => "LT_1" }'; then
  ok "  taken"
fi

# --- an observatory that probes through a freedom outbound sends its probes past the tunnel to
# a URL of the subscription's choice; outbound settings.reverse would open a portal (0.19.1 review)
perhost "burstObservatory selector picking the freedom outbound" '$b->{burstObservatory}{subjectSelector} = ["LT_", "dir"]'
if accepted "outbound settings.reverse" '$c->{outbounds}[0]{settings}{reverse} = { tag => "r" }'; then
  [ "$(j 'scalar grep { ref $_->{settings} eq "HASH" && exists $_->{settings}{reverse} } @{ $c->{outbounds} }')" = 0 ] && ok "  removed" || bad "  reverse: $(j '$c->{outbounds}[0]{settings}')"
fi

# a burst observatory's connectivity URL is fetched by Xray itself, past routing (measured on
# 26.9.30 with a blackhole as the only outbound): removed, named in the report (0.19.1 review 3)
if accepted "burstObservatory pingConfig.connectivity" ''; then
  [ "$(j 'join ",", sort keys %{ $c->{burstObservatory}{pingConfig} }')" = interval,sampling,timeout ] &&
    grep -q '"item":"burstObservatory.pingConfig.connectivity"' "$tmp/c.report" && ok "  removed, in the report" ||
    bad "  pingConfig: $(j '$c->{burstObservatory}{pingConfig}')"
fi
perhost "«Connectivity» in another case" '$b->{burstObservatory}{pingConfig}{Connectivity} = delete $b->{burstObservatory}{pingConfig}{connectivity}'
perhost "«PingConfig» in another case" '$b->{burstObservatory}{PingConfig} = delete $b->{burstObservatory}{pingConfig}'

# --- the host picked by hand left out by a refresh: the first one runs, and the journal says why
echo 'xrayserver=Плохой' > "$SETTINGS"; : > "$EVENTS"
edit 'my $b = JSON::PP->new->decode(JSON::PP->new->encode($c)); $b->{remarks} = "Плохой"; $b->{outbounds}[0]{settings}{vnext}[0]{address} = "0.0.0.0"; push @$a, $b'
if gen; then
  [ "$(j '$c->{selected}' "$tmp/c.report")" = "🇱🇹Литва" ] && grep -q 'xray: server «Плохой» left out of the subscription (its server address is unusable), «🇱🇹Литва» runs' "$EVENTS" &&
    ok "a picked host left out: the first runs, logged" || bad "picked host: $(j '$c->{selected}' "$tmp/c.report") events: $(cat "$EVENTS")"
else bad "picked host left out: refused: $(cat "$tmp/err")"; fi
: > "$SETTINGS"

# --- sockets bound past pf's view: interface, mark and raw socket options removed
if accepted "sockopt interface, mark, customSockopt, sendThrough" '$c->{outbounds}[0]{streamSettings}{sockopt}{interface} = "en0";
      $c->{outbounds}[0]{streamSettings}{sockopt}{mark} = 255; $c->{outbounds}[0]{sendThrough} = "192.168.1.5";
      $c->{outbounds}[0]{streamSettings}{sockopt}{customSockopt} = [{ level => "0", opt => "25", value => "4", type => "int" }];
      $c->{outbounds}[2]{sendThrough} = "origin"; $c->{outbounds}[2]{streamSettings}{sockopt}{customSockopt} = [{ opt => "25", value => "4" }]'; then
  [ "$(j 'join ",", grep { /interface|mark|customSockopt/ } map { keys %{ $_->{streamSettings}{sockopt} || {} } } @{ $c->{outbounds} }')" = "" ] &&
    [ "$(j 'scalar grep { exists $_->{sendThrough} } @{ $c->{outbounds} }')" = 0 ] &&
    ok "  all removed (servers and freedom alike)" || bad "  left: $(j '[map { [$_->{sendThrough}, $_->{streamSettings}{sockopt}] } @{ $c->{outbounds} }]')"
fi

# --- the transport itself may talk to other addresses than the pinned server (0.19.1 review 2,
# measured on Xray 26.9.30): ECH config fetched from a DNS server of the subscription's choice,
# finalmask realm (STUN, a rendezvous server), xdns (resolvers), xicmp (raw ICMP to any address),
# udphop to other addresses, xdrive (a storage service instead of the server). Such a host is left out
for e in '"udp://9.9.9.9"' '"a.example.com+https://1.1.1.1/dns-query"' '"h2c://1.1.1.1/dns-query"'; do
  perhost "ECH config from a DNS server $e" '$b->{outbounds}[0]{streamSettings}{security} = "tls"; $b->{outbounds}[0]{streamSettings}{tlsSettings} = { serverName => "a.example.com", echConfigList => '"$e"' }'
done
perhost "ECH config from DNS in an XHTTP download" '$b->{outbounds}[0]{streamSettings} = { network => "xhttp", xhttpSettings => { path => "/x",
      downloadSettings => { address => "198.51.100.8", port => 443, security => "tls", tlsSettings => { echConfigList => "udp://9.9.9.9" } } } }'
for m in realm REALM xdns xicmp; do
  perhost "finalmask $m" '$b->{outbounds}[0]{streamSettings}{finalmask} = { udp => [{ type => "'"$m"'", settings => { ips => ["198.51.100.1"], stunServers => ["198.51.100.2:3478"] } }] }'
done
perhost "finalmask udphop to other addresses" '$b->{outbounds}[0]{streamSettings}{finalmask} = { udp => [{ type => "udphop", settings => { remoteIPs => ["198.51.100.0/24"] } }] }'
perhost "finalmask xicmp on the freedom outbound" '$b->{outbounds}[2]{streamSettings}{finalmask} = { udp => [{ type => "xicmp" }] }'
perhost "network xdrive" '$b->{outbounds}[0]{streamSettings}{network} = "xdrive"'
perhost "method XDrive" '$b->{outbounds}[0]{streamSettings}{method} = "XDrive"'
if accepted "ECH from a config of its own, finalmask noise" '$c->{outbounds}[0]{streamSettings}{security} = "tls";
      $c->{outbounds}[0]{streamSettings}{tlsSettings} = { serverName => "a.example.com", echConfigList => "AEX+DQBBpQAgACB/RdTe" };
      $c->{outbounds}[0]{streamSettings}{finalmask} = { udp => [{ type => "noise", settings => { noise => [{ rand => "10-20", delay => "10-16" }] } }] }'; then
  ok "  taken"
fi
# the ECH lookup has a socket of its own (echSockopt): bound to nothing, like sockopt; a TLS key
# log is a file written by the core wherever the subscription says
if accepted "echSockopt interface, mark, customSockopt; masterKeyLog" '$c->{outbounds}[0]{streamSettings}{security} = "tls";
      $c->{outbounds}[0]{streamSettings}{tlsSettings} = { serverName => "a.example.com", echConfigList => "AEX+DQBBpQAgACB/RdTe", masterKeyLog => "/tmp/k",
        echSockopt => { interface => "en0", mark => 7, customSockopt => [{ opt => "25", value => "4" }] } };
      $c->{outbounds}[0]{streamSettings}{xhttpSettings} = { downloadSettings => { address => "198.51.100.8", port => 443, security => "tls",
        tlsSettings => { masterKeyLog => "/tmp/k2", echSockopt => { interface => "en0" } } } }'; then
  [ "$(j 'join ",", map { keys %$_ } $c->{outbounds}[0]{streamSettings}{tlsSettings}{echSockopt}, $c->{outbounds}[0]{streamSettings}{xhttpSettings}{downloadSettings}{tlsSettings}{echSockopt}')" = "" ] &&
    ! grep -q masterKeyLog "$tmp/c" && ok "  removed, in the download too" || bad "  tls: $(j '$c->{outbounds}[0]{streamSettings}')"
fi
# files the core (root) would read wherever the subscription says (#90): certificates and keys by
# path, in a download too and in any case, go whole and are named in the report
if accepted "certificateFile, keyFile in TLS certificates" '$c->{outbounds}[0]{streamSettings}{security} = "tls";
      $c->{outbounds}[0]{streamSettings}{tlsSettings} = { serverName => "a.example.com", keyFile => "/var/root/k0",
        certificates => [{ usage => "verify", certificateFile => "/etc/master.passwd" }, { keyFile => "/var/root/k1" }] };
      $c->{outbounds}[0]{streamSettings}{xhttpSettings} = { downloadSettings => { address => "198.51.100.8", port => 443, security => "tls",
        tlsSettings => { Certificates => [{ CertificateFile => "/etc/a", KEYFILE => "/etc/b" }] } } }'; then
  ! grep -qiE 'certificateFile|keyFile|/etc/|/var/root' "$tmp/c" &&
    [ "$(j '$c->{outbounds}[0]{streamSettings}{tlsSettings}{certificates}')" = "[]" ] &&
    [ "$(j 'join ",", sort map { $_->{item} } grep { $_->{section} eq "profile" && $_->{item} =~ /\Aoutbound / } @{ $c->{dropped} }' "$tmp/c.report")" = \
      "outbound LT_1: Certificates,outbound LT_1: certificates,outbound LT_1: keyFile" ] &&
    ok "  left out, in the download too, named in the report" || bad "  tls: $(j '$c->{outbounds}[0]{streamSettings}') dropped $(j '$c->{dropped}' "$tmp/c.report")"
fi
# a geodata list from a file (ext:file:tag and its other prefixes, negated too) in a routing rule:
# the rule goes, named in the report; geosite:/geoip: of the shipped files stay
n=$(j 'scalar @{ $c->[0]{routing}{rules} }' "$fx/xray-panel.json")
if accepted "ext: lists in routing rules" 'push @{$c->{routing}{rules}}, { domain => ["ext:../../../etc/hosts:x"], outboundTag => "direct" },
      { ip => ["!ext-ip:/etc/a:b"], outboundTag => "block" }, { source => ["ext:x.dat:y"], outboundTag => "block" },
      { domain => ["domain:ok.example.com", "EXT-DOMAIN:a:b"], outboundTag => "block" }, { domain => ["ext-site:a:b"], outboundTag => "block" },
      { sourceIP => ["ext:a:b"], outboundTag => "block" }, { localIP => [" ext:a:b"], outboundTag => "block" }'; then
  [ "$(j 'join ",", map { "$_->{index}:$_->{reason}" } grep { $_->{section} eq "rules" && $_->{index} >= '"$n"' } @{ $c->{dropped} }' "$tmp/c.report")" = \
    "$n:not-allowed,$((n + 1)):not-allowed,$((n + 2)):not-allowed,$((n + 3)):not-allowed,$((n + 4)):not-allowed,$((n + 5)):not-allowed,$((n + 6)):not-allowed" ] &&
    ! grep -qiE '"!? ?ext(-[a-z]+)?:' "$tmp/c" "$tmp/c.direct" && grep -q '"geosite:youtube"' "$tmp/c" &&
    ok "  each rule dropped, named in the report; geosite: stays" || bad "  rules: $(j '$c->{routing}{rules}') dropped $(j '$c->{dropped}' "$tmp/c.report")"
fi
# the same in DNS: a server with one (domains, expectedIPs, unexpectedIPs, any case) or a host entry
if accepted "ext: lists in DNS servers and hosts" '$c->{dns}{servers}[1]{domains} = ["ext:/etc/a:b"];
      $c->{dns}{servers}[2]{expectedIPs} = ["ext-ip:x:y"]; push @{$c->{dns}{servers}}, { address => "9.9.9.9", unexpectedIPs => ["!ext:a:b"] },
      { address => "9.9.9.10", Domains => ["ext-site:a:b"] }, "ext:a:b";
      $c->{dns}{hosts} = { "ext:/etc/a:b" => "1.2.3.4", "ok.example.com" => "1.2.3.4" }'; then
  [ "$(j 'join ",", map { ref $_ ? $_->{address} : $_ } @{ $c->{dns}{servers} }')" = 77.88.8.8 ] &&
    [ "$(j 'join ",", sort keys %{ $c->{dns}{hosts} }')" = ok.example.com ] &&
    [ "$(j 'join ",", map { $_->{item} } grep { $_->{section} eq "dns" && $_->{reason} eq "not-allowed" } @{ $c->{dropped} }' "$tmp/c.report")" = \
      "ext:/etc/a:b,8.8.8.8,1.1.1.1,9.9.9.9,9.9.9.10,ext:a:b" ] && ! grep -qiE '"!?ext(-[a-z]+)?:' "$tmp/c" &&
    ok "  left out, named in the report; geosite: stays" || bad "  dns: $(j '$c->{dns}') dropped $(j '$c->{dropped}' "$tmp/c.report")"
fi
# review of #108: a plain string is a list split on commas, any number of ! may lead a piece
n=$(j 'scalar @{ $c->[0]{routing}{rules} }' "$fx/xray-panel.json")
if accepted "ext: lists in routing rules: commas, several !" 'push @{$c->{routing}{rules}}, { domain => "domain:a.example.com,ext:/etc/x:y", outboundTag => "block" },
      { ip => "1.2.3.4, !!ext-ip:/etc/x:y", outboundTag => "block" }, { source => ["!!!ext:a:b"], outboundTag => "block" },
      { sourceIP => "10.0.0.1,ext-ip:a:b", outboundTag => "block" }, { domain => "domain:ok.example.com,domain:b.example.com", outboundTag => "block" }'; then
  [ "$(j 'join ",", map { $_->{index} } grep { $_->{section} eq "rules" && $_->{index} >= '"$n"' } @{ $c->{dropped} }' "$tmp/c.report")" = "$n,$((n + 1)),$((n + 2)),$((n + 3))" ] &&
    ! grep -qiE 'ext(-[a-z]+)?:' "$tmp/c" "$tmp/c.direct" && grep -q 'b.example.com' "$tmp/c" &&
    ok "  dropped piece by piece; a clean list stays" || bad "  rules: $(j '$c->{routing}{rules}') dropped $(j '$c->{dropped}' "$tmp/c.report")"
fi
if accepted "ext: lists in DNS: commas, several !, script" 'push @{$c->{dns}{servers}}, { address => "9.9.9.9", domains => "domain:a.com,ext:/etc/x:y" },
      { address => "9.9.9.10", expectedIPs => "1.1.1.1,!!ext-ip:/etc/x:y" }, { address => "9.9.9.11", unexpectedIPs => ["!!ext:a:b"] }, "domain:a.com,ext:a:b";
      $c->{dns}{hosts} = { "ok.example.com" => "1.2.3.4,ext-ip:a:b" }; $c->{dns}{Script} = "/etc/master.lua"'; then
  [ "$(j 'join ",", map { ref $_ ? $_->{address} : $_ } @{ $c->{dns}{servers} }')" = 77.88.8.8,8.8.8.8,1.1.1.1 ] &&
    [ "$(j 'join ",", sort keys %{ $c->{dns}{hosts} }')" = "" ] &&
    [ "$(j 'join ",", sort map { $_->{item} } grep { $_->{section} eq "dns" && $_->{reason} eq "not-allowed" } @{ $c->{dropped} }' "$tmp/c.report")" = \
      "9.9.9.10,9.9.9.11,9.9.9.9,Script,domain:a.com,ext:a:b,ok.example.com" ] &&
    ! grep -qiE 'ext(-[a-z]+)?:|script|master.lua' "$tmp/c" "$tmp/c.direct" &&
    ok "  left out, script too" || bad "  dns: $(j '$c->{dns}') dropped $(j '$c->{dropped}' "$tmp/c.report")"
fi
# freedom finalRules[].ip are geodata rules read at load by the core (root)
if accepted "ext: lists in freedom finalRules" 'my ($f) = grep { $_->{protocol} eq "freedom" } @{$c->{outbounds}};
      $f->{settings}{finalRules} = [{ action => "block", ip => ["ext:/etc/x:y"] }, { action => "allow", ip => "1.2.3.4,!!ext-ip:a:b" },
        { action => "block", ip => ["10.0.0.0/8"] }]'; then
  [ "$(j 'my ($f) = grep { $_->{protocol} eq "freedom" } @{$c->{outbounds}}; scalar @{ $f->{settings}{finalRules} }')" = 1 ] &&
    [ "$(j 'scalar grep { $_->{section} eq "profile" && $_->{item} =~ /: finalRules\z/ } @{ $c->{dropped} }' "$tmp/c.report")" = 2 ] &&
    ! grep -qiE 'ext(-[a-z]+)?:' "$tmp/c" "$tmp/c.direct" && grep -q '10.0.0.0/8' "$tmp/c" &&
    ok "  rules with a file list dropped, named in the report" || bad "  freedom: $(j '$c->{outbounds}') dropped $(j '$c->{dropped}' "$tmp/c.report")"
fi
refused "echSockopt dialerProxy to a missing outbound" '$c->{outbounds}[0]{streamSettings}{security} = "tls";
      $c->{outbounds}[0]{streamSettings}{tlsSettings} = { echConfigList => "AEX+DQBBpQAgACB/RdTe", echSockopt => { dialerProxy => "nope" } }' "несуществующий"

# --- tags: KillSwitch's own (ks-…) are not the subscription's to take, balancers and observers
# that would pick them (a prefix of "ks-") neither: «Программы без VPN» adds a freedom ks-direct
# that no direct signature counts
for t in ks-dns-out ks-block ks-direct ks-ping-0 ks-fetch ks-api ks-x; do
  perhost "outbound tag $t" 'push @{$b->{outbounds}}, { tag => "'"$t"'", protocol => "blackhole" }'
done
for s in "" k ks ks- ks-d; do
  perhost "balancer selector «${s}»" '$b->{routing}{balancers}[0]{selector} = ["LT_", "'"$s"'"]'
  perhost "burstObservatory selector «${s}»" '$b->{burstObservatory}{subjectSelector} = ["'"$s"'"]'
done
perhost "observatory selector «»" '$b->{observatory} = { subjectSelector => [""] }'
# a selector "" is not unset to Xray: one string becomes a list of it, and "" is a prefix of every
# tag, the freedom one and KillSwitch's among them (0.19.1 review, second round); only null is
for v in '""' '{}' 0; do
  perhost "balancer selector $v" '$b->{routing}{balancers}[0]{selector} = '"$v"
  perhost "burstObservatory selector $v" '$b->{burstObservatory}{subjectSelector} = '"$v"
done
# a balancer falls back to fallbackTag when every member is down: never KillSwitch's, only an
# outbound of the same host, and a freedom one counts in the direct signature
for f in ks-direct ks-block nope; do
  perhost "balancer fallbackTag «${f}»" '$b->{routing}{balancers}[0]{fallbackTag} = "'"$f"'"'
done
perhost "balancer fallbackTag a list" '$b->{routing}{balancers}[0]{fallbackTag} = ["LT_1"]'
if accepted "balancer fallbackTag to the subscription's freedom" '$c->{routing}{balancers}[0]{fallbackTag} = "direct";
      @{$c->{routing}{rules}} = grep { ($_->{outboundTag} // "") ne "direct" } @{$c->{routing}{rules}}'; then
  grep -q '^balancer	.*"direct"' "$tmp/c.direct" && grep -qx rules "$tmp/c.egress" && ok "  in the direct signature, the core may leave the tunnel for it" ||
    bad "  direct: $(cat "$tmp/c.direct") egress: $(cat "$tmp/c.egress")"
fi
echo 'splitapps=/Applications/Foo.app' > "$SETTINGS"
if accepted "a balancer of the subscription with «Программы без VPN» on" ''; then
  [ "$(j 'join ",", map { @{ $_->{selector} } } @{ $c->{routing}{balancers} }')" = LT_ ] && ok "  its selector cannot reach ks-direct" || bad "  balancers: $(j '$c->{routing}{balancers}')"
fi
: > "$SETTINGS"
if accepted "a rule to KillSwitch's ks-ping-0 or ks-fetch" 'unshift @{$c->{routing}{rules}}, { network => "tcp", outboundTag => "ks-ping-0" }, { network => "udp", outboundTag => "ks-fetch" }'; then
  [ "$(j 'scalar grep { ($_->{outboundTag} // "") =~ /\Aks-(ping|fetch)/ } @{ $c->{routing}{rules} }')" = 0 ] && ok "  dropped: no such target of the subscription" || bad "  rules: $(j '$c->{routing}{rules}')"
fi

# --- DNS: nothing that queries outside Xray's routing (+local) or outlives the core (fakedns)
for s in localhost LocalHost " localhost" fakedns "fakedns+others" " fakedns " "tcp+local://1.1.1.1" "TCP+LOCAL://1.1.1.1" "udp+local://1.1.1.1" \
         "https+local://1.1.1.1/dns-query" "h2c+local://1.1.1.1/dns-query" "quic+local://1.1.1.1"; do
  if accepted "DNS server «${s}»" '$c->{dns}{servers}[1]{address} = "'"$s"'"; push @{$c->{dns}{servers}}, "'"$s"'"'; then
    [ "$(j 'scalar grep { my $x = ref $_ ? $_->{address} : $_; $x =~ /local|fakedns/i } @{ $c->{dns}{servers} }')" = 0 ] &&
      grep -q '"reason":"bad-value"' "$tmp/c.report" && ok "  dropped (as a server object and as a string), named in the report" || bad "  dns: $(j '$c->{dns}{servers}')"
  fi
done
if accepted "the DNS outbound's own address" '$c->{outbounds}[4]{settings} = { address => "1.1.1.1", port => 53, network => "tcp" }'; then
  [ "$(j '$c->{outbounds}[4]{settings}')" = '{"nonIPQuery":"reject"}' ] && ok "  replaced: queries only to the signed DNS servers" || bad "  dns-out: $(j '$c->{outbounds}[4]')"
fi

# --- sections and keys the config never takes
if accepted "api, stats, reverse, fakedns, transport, inbounds of the panel" '$c->{api} = { tag => "api", services => ["HandlerService", "LoggerService"] };
      $c->{stats} = {}; $c->{reverse} = { portals => [{ tag => "p", domain => "x.example.com" }] }; $c->{fakedns} = [{ ipPool => "198.18.0.0/15" }];
      $c->{transport} = {}; push @{$c->{inbounds}}, { tag => "evil", protocol => "socks", listen => "0.0.0.0", port => 1080 }'; then
  [ "$(j 'join ",", sort keys %$c')" = "api,burstObservatory,dns,inbounds,log,outbounds,policy,routing,stats" ] &&
    [ "$(j 'join ",", @{ $c->{api}{services} }')" = StatsService,ObservatoryService ] &&
    [ "$(j 'join ",", map { $_->{tag} } @{ $c->{inbounds} }')" = ks-tun,ks-dns,ks-fetch ] &&
    ok "  only ours: the stats API on loopback, our three inbounds" || bad "  top: $(j 'join ",", sort keys %$c') api $(j '$c->{api}') in $(j '[map { $_->{tag} } @{ $c->{inbounds} }]')"
fi
if accepted "a rule with a webhook or an unknown key" 'unshift @{$c->{routing}{rules}}, { webhook => { url => "http://198.51.100.1/" }, outboundTag => "LT_1" }, { evil => 1, outboundTag => "direct" }'; then
  [ "$(j 'scalar grep { exists $_->{webhook} || exists $_->{evil} } @{ $c->{routing}{rules} }')" = 0 ] && ok "  dropped" || bad "  rules: $(j '$c->{routing}{rules}')"
fi
if accepted "a rule of the subscription for our inbounds" 'unshift @{$c->{routing}{rules}}, { inboundTag => ["ks-dns", "ks-fetch"], outboundTag => "direct" }'; then
  [ "$(j 'join "|", map { JSON::PP->new->canonical->encode($_) } @{ $c->{routing}{rules} }[0, 1]')" = \
    '{"inboundTag":["ks-dns"],"outboundTag":"dns-out"}|{"inboundTag":["ks-fetch"],"outboundTag":"LT_1"}' ] && ok "  ours still come first" || bad "  rules: $(j '$c->{routing}{rules}')"
fi

# --- the subscription is UTF-8: Xray reads an invalid byte as U+FFFD, so "dx\xFE" and "dx\xFF"
# are one tag to it and two to a byte-wise check; such a subscription is refused (0.19.1 review 3)
refused "invalid UTF-8 in a tag" '$c->{outbounds}[2]{tag} = "direct\xff"' "UTF-8"
refused "invalid UTF-8 in a name" '$c->{remarks} = "Lit\xc0\xafva"' "UTF-8"
refused "UTF-8 of a surrogate" '$c->{remarks} = "x\xed\xa0\x80"' "UTF-8"
# a subscription written with \u escapes (Python panels): names as they are, picked by name, and
# a refusal that names them in readable text (0.19.1 review 3)
esc() { /usr/bin/perl -Mutf8 -MJSON::PP -MEncode -e 'local $/; my $a = JSON::PP->new->decode(Encode::decode("UTF-8", <STDIN>)); my $c = $a->[0]; eval $ARGV[0]; die $@ if $@;
          print JSON::PP->new->ascii->encode($a)' "$1" < "$fx/xray-panel.json" > "$tmp/p.json"; }
esc 'my $b = JSON::PP->new->decode(JSON::PP->new->encode($c)); $b->{remarks} = "\x{1F1E9}\x{1F1EA}Германия"; push @$a, $b'
grep -q 'Литва' "$tmp/p.json" && bad "escaped subscription: not escaped" || ok "a subscription with \\u escapes only"
echo 'xrayserver=🇩🇪Германия' > "$SETTINGS"
if gen; then
  [ "$(j 'join "|", map { $_->{name} } @{ $c->{servers} }' "$tmp/c.report")" = "🇱🇹Литва|🇩🇪Германия" ] && [ "$(j '$c->{selected}' "$tmp/c.report")" = "🇩🇪Германия" ] &&
    ok "  names as written, the host picked by its name runs" || bad "  servers $(j '$c->{servers}' "$tmp/c.report") selected $(j '$c->{selected}' "$tmp/c.report")"
else bad "escaped subscription refused: $(cat "$tmp/err")"; fi
: > "$SETTINGS"
esc '$c->{outbounds}[0]{settings}{vnext}[0]{address} = "0.0.0.0"'
if gen; then bad "escaped subscription without a usable host: accepted"
else
  [ "$(head -1 "$tmp/err")" = "В подписке нет ни одного годного сервера (🇱🇹Литва: адрес сервера не годится)" ] &&
    ok "  refused with the host named in readable text" || bad "  refusal: $(head -c 300 "$tmp/err")"
fi

# --- every value the checks read or match on, mutated the ways Go and Perl read differently
# (0.19.1 review 3: Unicode whitespace that Go trims and Perl does not, İ that Go lowers to i,
# invalid bytes that Go makes U+FFFD): next to a good host the changed one is always left out, or
# the subscription refused; never taken with a meaning the checks did not see. Each field is
# "<value in $b> | <setup>", each variant "<lead|trail|in|first>:<text>" (~uXXXX~: a \u escape).
fields=(
  '$b->{outbounds}[2]{tag}|' '$b->{outbounds}[0]{tag}|' '$b->{outbounds}[2]{protocol}|' '$b->{outbounds}[0]{protocol}|'
  '$b->{outbounds}[0]{settings}{vnext}[0]{address}|'
  '$b->{outbounds}[0]{streamSettings}{network}|' '$b->{outbounds}[0]{streamSettings}{security}|'
  '$b->{outbounds}[0]{streamSettings}{sockopt}{domainStrategy}|'
  '$b->{outbounds}[1]{streamSettings}{sockopt}{dialerProxy}|$b->{outbounds}[1]{streamSettings}{sockopt}{dialerProxy} = "block"'
  '$b->{outbounds}[0]{streamSettings}{method}|$b->{outbounds}[0]{streamSettings}{method} = "xdrive"'
  '$b->{outbounds}[0]{streamSettings}{finalmask}{udp}[0]{type}|$b->{outbounds}[0]{streamSettings}{finalmask} = { udp => [{ type => "xicmp" }] }'
  '$b->{outbounds}[0]{streamSettings}{tlsSettings}{echConfigList}|$b->{outbounds}[0]{streamSettings}{tlsSettings} = { echConfigList => "udp://9.9.9.9" }'
  '$b->{routing}{rules}[0]{outboundTag}|' '$b->{routing}{rules}[1]{balancerTag}|' '$b->{routing}{rules}[0]{inboundTag}[0]|'
  '$b->{routing}{rules}[2]{port}|' '$b->{routing}{balancers}[0]{tag}|' '$b->{routing}{balancers}[0]{selector}[0]|'
  '$b->{routing}{balancers}[0]{fallbackTag}|' '$b->{burstObservatory}{subjectSelector}[0]|'
  '$b->{dns}{servers}[0]{address}|$b->{dns}{servers}[0]{address} = "tcp+local://9.9.9.9"'
  '$b->{dns}{servers}[3]|$b->{dns}{servers}[3] = "localhost"'
  '$b->{dns}{servers}[0]{tag}|' '$b->{dns}{queryStrategy}|'
)
variants=('lead:\xc2\xa0' 'trail:\xc2\xa0' 'lead:~u3000~' 'lead:\xe2\x80\xa8' 'trail:\xc2\x85' 'lead:~u200b~' 'in:\xc4\xb0' 'in:~u0131~'
          'in:\xc5\xbf' 'in:~u212a~' 'in:\xef\xbf\xbd' 'first:\xef\xbd\x98' 'in:\xff')
n=0; nbad=0
for f in "${fields[@]}"; do
  for v in "${variants[@]}"; do
    edit 'my $b = JSON::PP->new->decode(JSON::PP->new->encode($c)); $b->{remarks} = "Плохой"; '"${f#*|}"';
          my ($mode, $x) = split /:/, "'"$v"'", 2; my $v = '"${f%%|*}"' // "";
          '"${f%%|*}"' = $mode eq "lead" ? "$x$v" : $mode eq "trail" ? "$v$x" : $mode eq "in" ? substr($v, 0, 1) . $x . substr($v, 1) : $x . substr($v, 1);
          push @$a, $b'
    n=$((n + 1))
    if gen; then
      [ "$(j 'join "|", map { $_->{name} } @{ $c->{servers} }' "$tmp/c.report")" = "🇱🇹Литва" ] ||
        { bad "mutation ${f%%|*} $v: taken: servers $(j '$c->{servers}' "$tmp/c.report")"; nbad=$((nbad + 1)); }
    elif ! grep -q "UTF-8" "$tmp/err"; then bad "mutation ${f%%|*} $v: refused, but: $(head -c 200 "$tmp/err")"; nbad=$((nbad + 1)); fi
  done
done
[ "$nbad" = 0 ] && ok "$n mutations of ${#fields[@]} read values: the host left out (or the subscription refused) every time"

# --- messages say what is wrong in words (0.19.1 review 3)
edit 'delete $c->{outbounds}[0]{protocol}'
gen; grep -q '«»' "$tmp/err" && bad "protocol missing: an empty «» in: $(cat "$tmp/err")" || ok "protocol missing: no empty «» in the refusal"
edit '$c->{outbounds}[0]{streamSettings}{sockopt}{dialerProxy} = ["x"]'
gen; grep -q 'ARRAY(' "$tmp/err" && bad "dialerProxy a list: $(cat "$tmp/err")" || ok "dialerProxy a list: refused without a Perl reference in the text"
if accepted "DNS servers null, without an address, empty" 'push @{$c->{dns}{servers}}, undef, { address => undef }, {}'; then
  [ -s "$tmp/err" ] && bad "  warnings: $(head -c 200 "$tmp/err")" || ok "  no warnings"
fi

# --- names: shown, stored as xrayserver=, logged; no line breaks and no control characters
refused "a control character in a name" '$c->{remarks} = "a\x07b"' "Управляющие символы"
refused "a key longer than 256" '$c->{outbounds}[0]{"k" x 300} = 1'
if accepted "a line break in a name" '$c->{remarks} = "Real\nFake\r\tx"'; then
  [ "$(j '$c->{servers}[0]{name}' "$tmp/c.report")" = "Real Fake  x" ] && ok "  shown as spaces (one line per name for ks core select)" || bad "  name: $(j '$c->{servers}' "$tmp/c.report")"
fi
if accepted "shell and JSON in names, paths and hosts of the transport" '$c->{remarks} = "\$(id)`id`\"; rm -rf /";
      $c->{outbounds}[0]{streamSettings}{realitySettings}{spiderX} = "/\$(id)`id`;\"x"'; then
  [ "$(j '$c->{servers}[0]{name}' "$tmp/c.report")" = "\$(id)\`id\`\"; rm -rf /" ] && ok "  taken as text" || bad "  name: $(j '$c->{servers}' "$tmp/c.report")"
fi
# the choice of host by name never runs anything either
echo 'xrayserver=$(touch '"$tmp"'/ran)' > "$SETTINGS"
edit ''; gen; [ ! -e "$tmp/ran" ] && ok "a stored server name is never run" || bad "xrayserver ran"
: > "$SETTINGS"

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
