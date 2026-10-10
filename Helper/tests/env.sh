#!/bin/bash
# What root runs through passwordless sudo must not depend on the caller's environment: ks's own
# environment setup (ks_clean_env) under a hostile PATH, HOME and friends, the "bash -p" first
# line, "curl -q" everywhere, and the sudoers install.sh writes (checked with visudo -cf, no root).
# Nothing here runs ks as root or touches the system.
set -u
here=$(cd "$(dirname "$0")" && pwd)
KS="$here/../ks"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }

# --- ks_clean_env under a hostile environment: a fake curl first in PATH, the caller's HOME and
# CURL_HOME (~/.curlrc), proxies, perl and locale variables, an odd IFS
mkdir -p "$tmp/evil" "$tmp/home"
printf '#!/bin/sh\ntouch %s/ran\n' "$tmp" > "$tmp/evil/curl"; chmod +x "$tmp/evil/curl"
echo 'url = "http://203.0.113.1/"' > "$tmp/home/.curlrc"
out=$(env -i PATH="$tmp/evil:/usr/bin:/bin" HOME="$tmp/home" CURL_HOME="$tmp/home" TMPDIR="$tmp/home" \
  LC_ALL=en_US.UTF-8 LANG=ru_RU.UTF-8 LC_CTYPE=ru_RU.UTF-8 https_proxy=http://127.0.0.1:9 ALL_PROXY=socks5://127.0.0.1:9 \
  PERL5LIB="$tmp/home" PERL5OPT=-Mevil SSL_CERT_FILE="$tmp/home/ca" CURL_CA_BUNDLE="$tmp/home/ca" \
  KS_PINS="$tmp/home/pins" KS_STRICT_DNS= CDPATH="$tmp" GLOBIGNORE='*' \
  /bin/bash -c 'IFS=x; . "$1"
    printf "%s\n" "$PATH" "$(command -v curl)" "$HOME" "${CURL_HOME-unset}" "$LC_ALL" "${LANG-unset}" "${LC_CTYPE-unset}" \
      "$TMPDIR" "${https_proxy-unset}${ALL_PROXY-unset}" "${PERL5LIB-unset}${PERL5OPT-unset}" \
      "${SSL_CERT_FILE-unset}${CURL_CA_BUNDLE-unset}" "${KS_PINS-unset}${KS_STRICT_DNS-unset}" "${CDPATH-unset}${GLOBIGNORE-unset}" \
      "$(printf %s "$IFS" | od -An -tx1 | tr -d " ")"' _ "$KS")
line() { sed -n "${1}p" <<<"$out"; }
check "PATH: system directories only" "$(line 1)" "/usr/bin:/bin:/usr/sbin:/sbin"
check "curl is the system's" "$(line 2)" "/usr/bin/curl"
check "HOME is root's (no ~/.curlrc of the caller)" "$(line 3)" "/var/root"
check "CURL_HOME unset" "$(line 4)" "unset"
check "LC_ALL=C" "$(line 5)" "C"
check "LANG and LC_CTYPE unset" "$(line 6) $(line 7)" "unset unset"
check "TMPDIR not the caller's" "$(line 8)" "/private/tmp"
check "proxy variables unset" "$(line 9)" "unsetunset"
check "perl variables unset" "$(line 10)" "unsetunset"
check "TLS trust variables unset" "$(line 11)" "unsetunset"
check "internal KS_ variables unset" "$(line 12)" "unsetunset"
check "CDPATH and GLOBIGNORE unset" "$(line 13)" "unsetunset"
check "IFS back to space, tab, newline" "$(line 14)" "20090a"
[ -e "$tmp/ran" ] && check "the fake curl never ran" ran "not run" || check "the fake curl never ran" "not run" "not run"

# --- BASH_ENV runs before the first line of a script; "bash -p" ignores it (and ENV, SHELLOPTS,
# exported functions). sudoers drops it too, but ks must not rely on that alone.
check "first line of ks is #!/bin/bash -p" "$(head -1 "$KS")" "#!/bin/bash -p"
printf 'touch %s/benv\n' "$tmp" > "$tmp/benv.sh"
printf '#!/bin/bash\n:\n' > "$tmp/plain"; printf '#!/bin/bash -p\n:\n' > "$tmp/priv"; chmod +x "$tmp/plain" "$tmp/priv"
BASH_ENV="$tmp/benv.sh" "$tmp/plain"
[ -e "$tmp/benv" ] && check "(control) plain bash runs BASH_ENV" yes yes || check "(control) plain bash runs BASH_ENV" no yes
rm -f "$tmp/benv"
BASH_ENV="$tmp/benv.sh" "$tmp/priv"
[ -e "$tmp/benv" ] && check "bash -p ignores BASH_ENV" no yes || check "bash -p ignores BASH_ENV" yes yes

# --- every curl of ks starts with -q: no ~/.curlrc, whatever HOME is
check "every curl in ks is curl -q" "$(grep -nE 'curl -' "$KS" | grep -v 'curl -q ' | head -3)" ""
# root's own temporary directory once root
grep -q 'install -d -o root -g wheel -m 700 "$DIR/tmp" && export TMPDIR="$DIR/tmp"' "$KS" &&
  check "root's mktemp goes to a root-only directory" yes yes || check "root's mktemp goes to a root-only directory" no yes
for s in install.sh uninstall.sh; do
  grep -q '^PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH$' "$here/../$s" && grep -q '^unset CURL_HOME BASH_ENV ENV CDPATH$' "$here/../$s" &&
    check "$s cleans its environment" yes yes || check "$s cleans its environment" no yes
done

# --- the sudoers install.sh writes: valid, and ks gets a fixed PATH and none of the caller's
# HOME, CURL_HOME, BASH_ENV, ENV, LC_ALL
eval "$(sed -n '/^sudoers_text() {/,/^}/p' "$here/../install.sh")"
sudoers_text someone /Library/KillSwitch/ks > "$tmp/sudoers"
chmod 440 "$tmp/sudoers"
check "visudo -cf accepts it" "$(/usr/sbin/visudo -cf "$tmp/sudoers" >/dev/null 2>&1; echo $?)" 0
grep -qxF 'Defaults!/Library/KillSwitch/ks secure_path="/usr/bin:/bin:/usr/sbin:/sbin", env_reset' "$tmp/sudoers" &&
  check "secure_path and env_reset for ks" yes yes || check "secure_path and env_reset for ks" no yes
grep -qxF 'Defaults!/Library/KillSwitch/ks env_delete+="HOME CURL_HOME BASH_ENV ENV LC_ALL"' "$tmp/sudoers" &&
  check "env_delete for ks" yes yes || check "env_delete for ks" no yes
# with env_reset only env_keep counts: HOME (kept by macOS's sudoers) must leave it
kept=$(sed -n 's/^Defaults!\/Library\/KillSwitch\/ks env_keep-="\(.*\)"$/\1/p' "$tmp/sudoers")
for v in HOME MAIL LANG LC_ALL LC_CTYPE TZ SSH_AUTH_SOCK; do
  [[ " $kept " == *" $v "* ]] || check "env_keep-= has $v" no yes
done
check "the passwordless commands are unchanged" "$(grep -c 'NOPASSWD: /Library/KillSwitch/ks state, /Library/KillSwitch/ks probe, /Library/KillSwitch/ks on, /Library/KillSwitch/ks netrestore, /Library/KillSwitch/ks core state, /Library/KillSwitch/ks core on, /Library/KillSwitch/ks core off, /Library/KillSwitch/ks core proxies, /Library/KillSwitch/ks core select \*, /Library/KillSwitch/ks core delay \*, /Library/KillSwitch/ks core refresh \*$' "$tmp/sudoers")" 1

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
