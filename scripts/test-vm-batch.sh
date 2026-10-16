#!/bin/bash
# shellcheck disable=SC2034 # rc, sha, tree are read inside the check strings (eval)
# Tests scripts/vm-batch.sh on a local bare "origin" with PR heads as refs/pull/N/head, a fake gate
# (red when the tree has a file BAD) and a fake gh. No network, no VM.
set -eu
batch="$(cd "$(dirname "$0")" && pwd)/vm-batch.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/test-vm-batch.XXXXXX")
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@localhost GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@localhost
export GIT_CONFIG_NOSYSTEM=1 HOME="$T"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# origin: rel + PRs 1-3 (own files), 4 (adds BAD), 5 (conflicts with 1 on a.txt)
git init -q --bare "$T/origin.git"; git --git-dir="$T/origin.git" symbolic-ref HEAD refs/heads/rel
git init -q -b rel "$T/seed"
cd "$T/seed"
echo base > base.txt; git add base.txt; git commit -qm base
git push -q "$T/origin.git" rel
pr() { # pr <N> <file> <content>
  git checkout -q -b "p$1" rel
  echo "$3" > "$2"; git add "$2"; git commit -qm "pr $1"
  git push -q "$T/origin.git" "p$1:refs/pull/$1/head"
}
git checkout -q -b bad rel; echo bad > BAD; git add BAD; git commit -qm "bad base"; git push -q "$T/origin.git" bad
pr 1 a.txt one; pr 2 b.txt two; pr 3 c.txt three; pr 4 BAD bad; pr 5 a.txt five
git clone -q "$T/origin.git" "$T/work"

cat > "$T/gate" <<'EOF'
#!/bin/bash
echo "$1" >> "$T/gates"
[ -z "$(git ls-tree "$1" BAD)" ]
EOF
cat > "$T/gate-error" <<'EOF'
#!/bin/bash
echo "$1" >> "$T/gates"; exit 2
EOF
cat > "$T/gh" <<'EOF'
#!/bin/bash
[ "$1" = repo ] && { echo o/ks; exit 0; }
[ "$1" = -R ] && shift 2
case "$1 $2" in
  "pr view") n=$3; b=rel; [ -f "$T/base.$n" ] && b=$(cat "$T/base.$n"); st=OPEN; [ -f "$T/state.$n" ] && st=$(cat "$T/state.$n")
    h=$(git --git-dir="$T/origin.git" rev-parse "refs/pull/$n/head"); echo x >> "$T/views.$n"
    [ -f "$T/moved.$n" ] && [ "$(wc -l < "$T/views.$n")" -ge 2 ] && h=0000000000000000000000000000000000000000
    echo "$st $b $h";;
  "pr comment") printf '== #%s\n%s\n' "$3" "$5" >> "$T/comments";;
  *) echo "fake gh: $*" >&2; exit 1;;
esac
EOF
cat > "$T/gate-moves" <<'EOF'
#!/bin/bash
echo "$1" >> "$T/gates"
g="git --git-dir=$T/origin.git"
$g update-ref refs/heads/rel "$($g commit-tree 'rel^{tree}' -p rel -m moved)"
EOF
chmod +x "$T/gate" "$T/gate-error" "$T/gate-moves" "$T/gh"
export T KS_GH="$T/gh" KS_BATCH_GATE="$T/gate"

run() { # run <args...>: sets rc, out (stdout), last; logs reset
  rm -f "$T/gates" "$T/comments" "$T"/views.*; touch "$T/gates" "$T/comments"
  set +e; out=$(cd "$T/work" && "$batch" "$@" 2> "$T/stderr"); rc=$?; set -e
  last=$(printf '%s\n' "$out" | tail -n 1)
}
gates() { wc -l < "$T/gates" | tr -d ' '; }
green_comment() { grep -A1 "^== #$1\$" "$T/comments" | grep -q "^ci-local batch [0-9a-f]\{40\}: green\$"; }

echo master > "$T/base.2"
run check rel 1 2 3
check "wrong base: exit 2" '[ "$rc" = 2 ]'
check "wrong base: nothing gated" '[ "$(gates)" = 0 ]'
check "wrong base: names the PR" 'grep -q "#2" "$T/stderr"'
rm "$T/base.2"

KS_BATCH_GATE="$T/gate-error" run check rel 1 2
check "gate error: exit 2" '[ "$rc" = 2 ]'
check "gate error: nothing posted" '[ ! -s "$T/comments" ]'

run check rel 1 5 2
check "conflict: exit 0" '[ "$rc" = 0 ]'
check "conflict: one gate run" '[ "$(gates)" = 1 ]'
check "conflict: #5 excluded" 'printf "%s\n" "$out" | grep -q "^excluded: #5 (conflicts)"'
check "conflict: last line green #1 #2" 'echo "$last" | grep -q "^vm-batch [0-9a-f]*: green #1 #2 tree [0-9a-f]*\$"'
check "conflict: #5 told" 'grep -A1 "^== #5\$" "$T/comments" | grep -q "^ci-local batch: not merged — conflicts\$"'
check "conflict: #1 #2 green" 'green_comment 1 && green_comment 2'

run check rel 1 2 4 3
check "bad: exit 0" '[ "$rc" = 0 ]'
check "bad: #4 excluded" 'printf "%s\n" "$out" | grep -q "^excluded: #4 (red when #4 is added)"'
check "bad: last line green #1 #2 #3" 'echo "$last" | grep -q "^vm-batch [0-9a-f]*: green #1 #2 #3 tree "'
check "bad: #4 told" 'grep -A1 "^== #4\$" "$T/comments" | grep -q "^ci-local batch: not merged — red when #4 is added\$"'
check "bad: #1 #2 #3 green" 'green_comment 1 && green_comment 2 && green_comment 3'
sha=$(echo "$last" | sed 's/^vm-batch \([0-9a-f]*\):.*/\1/')
check "bad: batch has no BAD" '[ -z "$(git -C "$T/work" ls-tree "$sha" BAD)" ]'
check "bad: at most 4 gate runs (1 + log2 4 + 1)" '[ "$(gates)" -le 4 ]'
check "bad: no tree gated twice" '[ "$(cd "$T/work" && while read -r s; do git rev-parse "$s^{tree}"; done < "$T/gates" | sort | uniq -d)" = "" ]'

run check rel 4
check "only bad: exit 1" '[ "$rc" = 1 ]'
check "only bad: nothing green" '[ "$last" = "vm-batch: red, nothing green" ]'
check "only bad: only #4 told, no green" 'grep -A1 "^== #4\$" "$T/comments" | grep -q "^ci-local batch: not merged — red when #4 is added\$" &&
  ! grep -q ": green\$" "$T/comments"'

run check rel 4 1 2
check "culprit first: exit 0, #4 out" '[ "$rc" = 0 ] && printf "%s\n" "$out" | grep -q "^excluded: #4 (red when #4 is added)"'
check "culprit first: green #1 #2" 'echo "$last" | grep -q "^vm-batch [0-9a-f]*: green #1 #2 tree "'

run check rel 1 2 4 3 5
check "mixed: conflict and red both told before any green" '[ "$(grep "^== #" "$T/comments" | head -n 2 | sort | tr "\n" " ")" = "== #4 == #5 " ]'

echo bad > "$T/base.1"; echo bad > "$T/base.2"
run check bad 1 2
check "base red: exit 1" '[ "$rc" = 1 ] && printf "%s\n" "$out" | grep -q "base bad itself is red"'
check "base red: nothing posted" '[ ! -s "$T/comments" ]'
rm "$T/base.1" "$T/base.2"

echo CLOSED > "$T/state.2"
run check rel 1 2
check "not open: exit 2, nothing gated or posted" '[ "$rc" = 2 ] && [ "$(gates)" = 0 ] && [ ! -s "$T/comments" ]'
rm "$T/state.2"

run check rel 1 2 1
check "duplicate PR: exit 2" '[ "$rc" = 2 ] && [ "$(gates)" = 0 ] && grep -q "twice" "$T/stderr"'

touch "$T/moved.2"
run check rel 1 2
check "head moved: exit 3, no green posted" '[ "$rc" = 3 ] && [ ! -s "$T/comments" ] && grep -q "head moved" "$T/stderr"'
rm "$T/moved.2"

run check rel 1 2 3
check "good: exit 0" '[ "$rc" = 0 ]'
check "good: one gate run" '[ "$(gates)" = 1 ]'
check "good: each PR green" 'green_comment 1 && green_comment 2 && green_comment 3'
check "good: merge order is #1 #2 #3" '[ "$(grep -o "^#[0-9]* (" "$T/comments" | head -n 3 | tr -d "( \n")" = "#1#2#3" ]'
check "good: batch commits use the fixed identity" '[ "$(git -C "$T/work" log -1 --format=%an "$(echo "$last" | sed "s/^vm-batch \([0-9a-f]*\):.*/\1/")")" = vm-batch ]'
check "good: no excluded line" '! printf "%s\n" "$out" | grep -q "^excluded:"'
sha=$(echo "$last" | sed 's/^vm-batch \([0-9a-f]*\):.*/\1/'); tree=${last##* }
check "good: comment names base, order, tree, landed" 'grep -q "^#1 ($(git --git-dir="$T/origin.git" rev-parse refs/pull/1/head))\$" "$T/comments" &&
  grep -q "^tree $tree\$" "$T/comments" && grep -q "scripts/vm-batch.sh landed rel $tree" "$T/comments" &&
  grep -q "^base rel@$(git --git-dir="$T/origin.git" rev-parse rel)\$" "$T/comments"'
check "good: no worktree or refs left" '[ -z "$(git -C "$T/work" for-each-ref refs/vm-batch)" ] &&
  [ "$(git -C "$T/work" worktree list | wc -l | tr -d " ")" = 1 ]'
check "good: tree is the batch tree" '[ "$(git -C "$T/work" rev-parse "$sha^{tree}")" = "$tree" ]'

# land the PRs as GitHub squash does, in the posted order, onto the bare origin's base
git clone -q "$T/origin.git" "$T/land"
squash() { # squash <N...>
  local n
  for n in "$@"; do
    git -C "$T/land" fetch -q origin rel "refs/pull/$n/head"
    git -C "$T/land" checkout -q --detach origin/rel
    git -C "$T/land" merge -q --squash FETCH_HEAD >/dev/null 2>&1
    git -C "$T/land" commit -qm "squash #$n"
    git -C "$T/land" push -q origin HEAD:refs/heads/rel
  done
}
# shellcheck disable=SC2046 # PR numbers, one per word
squash $(grep -o '^#[0-9]* (' "$T/comments" | head -n 3 | tr -d '#( ')
run landed rel "$tree"
check "landed: after real squash merges, exit 0" '[ "$rc" = 0 ] && echo "$last" | grep -q "is the tested tree $tree\$"'
cd "$T/seed"; git fetch -q "$T/origin.git" rel; git checkout -q -B rel FETCH_HEAD
echo extra > extra.txt; git add extra.txt; git commit -qm extra; git push -q "$T/origin.git" rel
run landed rel "$tree"
check "landed: extra commit, exit 1" '[ "$rc" = 1 ] && echo "$last" | grep -q "scripts/vm.sh origin/rel"'

KS_BATCH_GATE="$T/gate-moves" run check rel 1 2
check "base moved during the gate: exit 3, nothing posted" '[ "$rc" = 3 ] && [ ! -s "$T/comments" ] && grep -q "base rel moved" "$T/stderr"'

[ "$fails" = 0 ] && echo "test-vm-batch: all passed" || { echo "test-vm-batch: $fails failed"; exit 1; }
