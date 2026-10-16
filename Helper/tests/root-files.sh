#!/bin/bash
# What the root-side scripts (ks, install.sh, uninstall.sh) read and write: never a file in a place
# the user can write, only the app bundle and /Library/KillSwitch; the geodata they install is the
# pinned one. Static checks and extracted functions only: nothing runs as root.
set -u
here=$(cd "$(dirname "$0")" && pwd)
H="$here/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }
code() { grep -vE '^[[:space:]]*#' "$1"; }   # without comment lines

# --- no user-writable source in root code: home folders, dropweb's and Happ's data
for s in ks install.sh uninstall.sh; do
  check "$s: no path under a user's home" \
    "$(code "$H/$s" | grep -nE '/Users/|Application Support|Group Containers|\$HOME|\$\{HOME|~/|org\.dropweb|ffg\.happ' | head -3)" ""
done

# --- geodata: from the bundle (install.sh runs in Helper/ of the app), pinned by sha256
check "install.sh installs geoip.metadb from the bundle, checked against the pin (#27)" \
  "$(code "$H/install.sh" | grep -c 'geodata_put geoip.metadb; then')" 1
check "geodata_put: only the three geodata files, into core/" \
  "$(code "$H/install.sh" | grep -oE 'geodata_put [^ ;]+' | sort -u | paste -sd' ' -) $(code "$H/install.sh" | grep -c 'put_file "\$1" "\$DIR/core/\$1" 644')" \
  "geodata_put geoip.dat geodata_put geoip.metadb geodata_put geosite.dat 1"
check "install.sh removes a geoip.metadb the bundle does not have" \
  "$(code "$H/install.sh" | grep -c 'rm -f "\$DIR/core/geoip.metadb"; restart=1')" 1
# put_file installs only what install.sh runs in: the bundle's Helper/ (cd "$(dirname "$0")")
check "put_file sources are bundle file names" \
  "$(code "$H/install.sh" | grep -oE 'put_file [^ ]+' | grep -vE '^put_file ("\$1"|ks|mihomo|xray|geosite\.dat|geoip\.metadb|tsrelays|local\.killswitch(\.core(\.xray)?)?\.plist)$' | head -3)" ""
for v in SHA256_GEOSITE SHA256_GEOIP SHA256_GEOIP_DAT; do
  pin=$(sed -nE "s/^$v=\"([0-9a-f]{64})\".*/\1/p" "$H/fetch-geodata.sh")
  [ -n "$pin" ] && check "fetch-geodata.sh pins $v" yes yes || check "fetch-geodata.sh pins $v" no yes
  f=geosite.dat; [ "$v" = SHA256_GEOIP ] && f=geoip.metadb; [ "$v" = SHA256_GEOIP_DAT ] && f=geoip.dat
  if [ -f "$H/$f" ]; then
    check "Helper/$f is the pinned file" "$(shasum -a 256 "$H/$f" | cut -d' ' -f1)" "$pin"
  else
    echo "skip  Helper/$f is the pinned file (not fetched: Helper/fetch-geodata.sh)"
  fi
done
check "geoip.metadb is not committed" "$(grep -cx 'Helper/geoip.metadb' "$here/../../.gitignore")" 1

# --- every key settings_lines_ok accepts is in SETTING_KEYS (else it is logged as unknown on every change)
okkeys=$(sed -n '/^settings_lines_ok()/,/^}/p' "$H/ks" | sed -nE 's/^      ([^)]*)\).*/\1/p' | grep -oE '[a-z][a-z0-9_]*=' | tr -d = | sort -u)
listed=$(sed -nE 's/^SETTING_KEYS=" (.*) "$/\1/p' "$H/ks" | tr ' ' '\n' | sort -u)
check "settings_lines_ok keys are all in SETTING_KEYS" "$(comm -23 <(echo "$okkeys") <(echo "$listed") | paste -sd' ' -)" ""
check "the key scan found the case list" "$([ "$(echo "$okkeys" | wc -l)" -ge 15 ] && echo yes)" yes

# --- a function run into `head` gets SIGPIPE (141) and the ERR trap (set -E) prints "exit 141": read all input (sed -n 1p)
check "install.sh/uninstall.sh: no ks_run piped into head" \
  "$({ code "$H/install.sh"; code "$H/uninstall.sh"; } | grep -E 'ks_run[^|]*\| *head' | head -3)" ""

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
