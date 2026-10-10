#!/bin/bash
# Checks where Helper/fetch-geodata.sh takes geosite.dat and geoip.metadb from (curl replaced,
# nothing downloaded): our releases' copy first, the pinned meta-rules-dat commit if that is
# missing or differs, and never a file whose sha256 is not the pinned one. Also release.sh's check
# of Helper/geosite.dat and Helper/geoip.metadb.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }

printf 'pinned geosite\n' > "$tmp/good.dat"
printf 'pinned geoip\n' > "$tmp/good.metadb"
printf 'something else\n' > "$tmp/bad"
pin_site=$(shasum -a 256 < "$tmp/good.dat" | cut -d' ' -f1)
pin_ip=$(shasum -a 256 < "$tmp/good.metadb" | cut -d' ' -f1)

# The script writes next to itself: a copy with the test's pins.
mkdir "$tmp/Helper" "$tmp/bin"
sed -e "s/^SHA256_GEOSITE=\"[0-9a-f]*\"/SHA256_GEOSITE=\"$pin_site\"/" \
    -e "s/^SHA256_GEOIP=\"[0-9a-f]*\"/SHA256_GEOIP=\"$pin_ip\"/" "$here/../fetch-geodata.sh" > "$tmp/Helper/fetch-geodata.sh"
# curl -q -fsSL -o <file> <url>: serves "$FAKE_COPY.<ext>" or "$FAKE_UPSTREAM.<ext>" (.dat for
# geosite.dat, .metadb for geoip.metadb; empty FAKE_* for a 404), logs "<file>@<source>".
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac; done
file=${url##*/}
case "$url" in
  https://github.com/lesha19/KillSwitch-releases/*) src=$FAKE_COPY; echo "$file@copy" >> "$LOG" ;;
  https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/*) src=$FAKE_UPSTREAM; echo "$file@upstream" >> "$LOG" ;;
  *) src=""; echo "$url" >> "$LOG" ;;
esac
[ -n "$src" ] || exit 22
cp "$src.${file##*.}" "$out"
EOF
chmod +x "$tmp/bin/curl"
cp "$tmp/bad" "$tmp/bad.dat"; cp "$tmp/bad" "$tmp/bad.metadb"
good="$tmp/good" bad="$tmp/bad"
export LOG="$tmp/log"
run() {  # run <copy|""> <upstream|"">: "<exit> <files asked, in order> <geosite.dat>/<geoip.metadb>"
  rm -f "$tmp/Helper/geosite.dat" "$tmp/Helper/geoip.metadb" "$LOG"; : > "$LOG"
  FAKE_COPY=$1 FAKE_UPSTREAM=$2 PATH="$tmp/bin:$PATH" bash "$tmp/Helper/fetch-geodata.sh" >/dev/null 2>&1
  local rc=$? site=none ip=none
  [ -f "$tmp/Helper/geosite.dat" ] && site=$(cat "$tmp/Helper/geosite.dat")
  [ -f "$tmp/Helper/geoip.metadb" ] && ip=$(cat "$tmp/Helper/geoip.metadb")
  echo "$rc $(paste -sd, - < "$LOG") $site/$ip"
}

check "our releases' copies first" "$(run "$good" "$good")" \
  "0 geosite.dat@copy,geoip.metadb@copy pinned geosite/pinned geoip"
check "no copies there: the pinned commit" "$(run "" "$good")" \
  "0 geosite.dat@copy,geosite.dat@upstream,geoip.metadb@copy,geoip.metadb@upstream pinned geosite/pinned geoip"
check "copies of another pin: the pinned commit" "$(run "$bad" "$good")" \
  "0 geosite.dat@copy,geosite.dat@upstream,geoip.metadb@copy,geoip.metadb@upstream pinned geosite/pinned geoip"
check "pinned commit gone: the copies are enough" "$(run "$good" "")" \
  "0 geosite.dat@copy,geoip.metadb@copy pinned geosite/pinned geoip"
check "neither: fails, nothing written" "$(run "" "")" "1 geosite.dat@copy,geosite.dat@upstream none/none"
check "wrong sha256 everywhere: fails, nothing written" "$(run "$bad" "$bad")" "1 geosite.dat@copy,geosite.dat@upstream none/none"
check "  no temporary file left" "$(ls "$tmp/Helper")" "fetch-geodata.sh"
check "every download with curl -q (no ~/.curlrc)" \
  "$(grep -vE '^[[:space:]]*#' "$here/../fetch-geodata.sh" | grep -E '(^|[^-])curl ' | grep -vc 'curl -q ')" 0

# release.sh refuses geodata that is not the pinned one (root installs it, and it is uploaded as the copy).
# shellcheck source=../../scripts/release.sh
. "$here/../../scripts/release.sh"
for f in geosite.dat:good.dat geoip.metadb:good.metadb; do
  name=${f%%:*}
  cp "$tmp/${f#*:}" "$tmp/Helper/$name"
  check "release: pinned $name accepted" "$(geodata_pinned "$tmp/Helper" "$name" && echo yes || echo no)" yes
  cp "$tmp/bad" "$tmp/Helper/$name"
  check "release: other $name refused" "$(geodata_pinned "$tmp/Helper" "$name" && echo yes || echo no)" no
  rm "$tmp/Helper/$name"
  check "release: missing $name refused" "$(geodata_pinned "$tmp/Helper" "$name" && echo yes || echo no)" no
done
cp "$tmp/good.dat" "$tmp/Helper/geoip.metadb"
check "release: geosite.dat in place of geoip.metadb refused" \
  "$(geodata_pinned "$tmp/Helper" geoip.metadb && echo yes || echo no)" no

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
