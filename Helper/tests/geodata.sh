#!/bin/bash
# Checks where Helper/fetch-geodata.sh takes geosite.dat from (curl replaced, nothing downloaded):
# our releases' copy first, the pinned meta-rules-dat commit if that is missing or differs, and
# never a file whose sha256 is not the pinned one. Also release.sh's check of Helper/geosite.dat.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }

printf 'pinned geodata\n' > "$tmp/good"
printf 'something else\n' > "$tmp/bad"
pin=$(shasum -a 256 < "$tmp/good" | cut -d' ' -f1)

# The script writes next to itself: a copy with the test's pin.
mkdir "$tmp/Helper" "$tmp/bin"
sed "s/^SHA256=\"[0-9a-f]*\"/SHA256=\"$pin\"/" "$here/../fetch-geodata.sh" > "$tmp/Helper/fetch-geodata.sh"
# curl -fsSL -o <file> <url>: serves $FAKE_COPY or $FAKE_UPSTREAM (a path, or empty for a 404), logs the url.
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac; done
echo "$url" >> "$LOG"
case "$url" in
  https://github.com/lesha19/KillSwitch-releases/*) src=$FAKE_COPY ;;
  https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/*) src=$FAKE_UPSTREAM ;;
  *) src="" ;;
esac
[ -n "$src" ] || exit 22
cp "$src" "$out"
EOF
chmod +x "$tmp/bin/curl"
export LOG="$tmp/log"
run() {  # run <mirror file|""> <upstream file|"">: "<exit> <sources asked> <result>"
  rm -f "$tmp/Helper/geosite.dat" "$LOG"; : > "$LOG"
  FAKE_COPY=$1 FAKE_UPSTREAM=$2 PATH="$tmp/bin:$PATH" bash "$tmp/Helper/fetch-geodata.sh" >/dev/null 2>&1
  local rc=$? result=none
  [ -f "$tmp/Helper/geosite.dat" ] && result=$(cat "$tmp/Helper/geosite.dat")
  echo "$rc $(sed -E 's#^https://(github.com/lesha19|raw.githubusercontent.com/MetaCubeX)/.*#\1#' "$LOG" | paste -sd, -) $result"
}

check "our releases' copy first" "$(run "$tmp/good" "$tmp/good")" "0 github.com/lesha19 pinned geodata"
check "no copy there: the pinned commit" "$(run "" "$tmp/good")" "0 github.com/lesha19,raw.githubusercontent.com/MetaCubeX pinned geodata"
check "a copy of another pin: the pinned commit" "$(run "$tmp/bad" "$tmp/good")" "0 github.com/lesha19,raw.githubusercontent.com/MetaCubeX pinned geodata"
check "pinned commit gone: the copy is enough" "$(run "$tmp/good" "")" "0 github.com/lesha19 pinned geodata"
check "neither: fails, nothing written" "$(run "" "")" "1 github.com/lesha19,raw.githubusercontent.com/MetaCubeX none"
check "wrong sha256 everywhere: fails, nothing written" "$(run "$tmp/bad" "$tmp/bad")" "1 github.com/lesha19,raw.githubusercontent.com/MetaCubeX none"
check "  no temporary file left" "$(ls "$tmp/Helper")" "fetch-geodata.sh"

# release.sh refuses a Helper/geosite.dat that is not the pinned one (it is uploaded as the copy).
# shellcheck source=../../scripts/release.sh
. "$here/../../scripts/release.sh"
cp "$tmp/good" "$tmp/Helper/geosite.dat"
check "release: pinned file accepted" "$(geosite_pinned "$tmp/Helper" && echo yes || echo no)" yes
cp "$tmp/bad" "$tmp/Helper/geosite.dat"
check "release: other file refused" "$(geosite_pinned "$tmp/Helper" && echo yes || echo no)" no
rm "$tmp/Helper/geosite.dat"
check "release: missing file refused" "$(geosite_pinned "$tmp/Helper" && echo yes || echo no)" no

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
