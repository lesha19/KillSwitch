#!/bin/bash
# Checks Helper/fetch-xray.sh against a fake curl (nothing downloaded): the pinned zip is
# unpacked, signed and kept; a zip of another sha256 is refused and the old binary stays.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }

mkdir -p "$tmp/Helper" "$tmp/scripts" "$tmp/bin" "$tmp/good" "$tmp/bad"
printf '#!/bin/sh\necho "Xray 26.9.30 (fake)"\n' > "$tmp/good/xray"; chmod 755 "$tmp/good/xray"
printf '#!/bin/sh\necho evil\n' > "$tmp/bad/xray"; chmod 755 "$tmp/bad/xray"
(cd "$tmp/good" && zip -q ../good.zip xray) && (cd "$tmp/bad" && zip -q ../bad.zip xray)
pin=$(shasum -a 256 < "$tmp/good.zip" | cut -d' ' -f1)
sed -e "s/^SHA256=[0-9a-f]*/SHA256=$pin/" "$here/../fetch-xray.sh" > "$tmp/Helper/fetch-xray.sh"
printf '#!/bin/sh\necho "$1" >> "%s/signed"\n' "$tmp" > "$tmp/scripts/sign-core.sh"; chmod 755 "$tmp/scripts/sign-core.sh"
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac; done
echo "$url" >> "$LOG"
cp "$FAKE_ZIP" "$out"
CURL
chmod +x "$tmp/bin/curl"
export LOG="$tmp/log"

out=$(FAKE_ZIP="$tmp/good.zip" PATH="$tmp/bin:$PATH" bash "$tmp/Helper/fetch-xray.sh" 2>&1)
check "pinned zip: binary in place" "$("$tmp/Helper/xray" version)" "Xray 26.9.30 (fake)"
check "  signed as our core" "$(cat "$tmp/signed")" "Helper/xray"
check "  the version printed" "$out" "Xray 26.9.30 (fake)"
check "  from the pinned tag's macOS arm64 zip" "$(cat "$LOG")" \
  "https://github.com/XTLS/Xray-core/releases/download/v26.9.30/Xray-macos-arm64-v8a.zip"
FAKE_ZIP="$tmp/bad.zip" PATH="$tmp/bin:$PATH" bash "$tmp/Helper/fetch-xray.sh" >/dev/null 2>&1
check "another sha256: refused" "$?" 1
check "  the old binary stays" "$("$tmp/Helper/xray" version)" "Xray 26.9.30 (fake)"
check "  nothing else left in Helper" "$(ls "$tmp/Helper" | paste -sd' ' -)" "fetch-xray.sh xray"
check "every curl -q with a time limit" \
  "$(grep -vE '^[[:space:]]*#' "$here/../fetch-xray.sh" | grep -E '(^|[^-])curl ' | grep -vc 'curl -q --max-time')" 0

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
