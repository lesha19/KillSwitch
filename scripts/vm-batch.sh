#!/bin/bash
# Gates a batch of reviewed PRs once: the merge of all of them, in the given order, onto origin/<base>,
# through the merge gate (scripts/vm.sh). A PR that conflicts is left out; a red batch is bisected on
# prefixes and the first PR that turns it red is left out, then the rest is gated again. Results are kept
# per tree, so no tree is gated twice. The green set and the merge order are posted on each PR.
#   scripts/vm-batch.sh check <base-branch> <PR> [<PR>...]
#   scripts/vm-batch.sh landed <base-branch> <tree>   after the squash merges: is origin/<base> that tree?
# check: exit 0 = a green set posted (some PRs may be left out), 1 = nothing green or the base itself is
# red, 2 = usage, a duplicate PR, a PR not open or on another base, or a gate error (gate exit not 0/1),
# 3 = a PR head or the base tip moved since the build (gate again), or a post failed.
# Left-out PRs get a "not merged" comment before the green ones are posted (also when nothing is green,
# but not when the base is red). Merges use a fixed identity, no signing, no hooks.
# landed: exit 0 = the tip is the tested tree, 1 = it is not.
# Env: KS_BATCH_GATE (default scripts/vm.sh, run as "$gate <sha>"), KS_GH (default gh).
set -u
usage() { echo "usage: $0 check <base-branch> <PR>... | landed <base-branch> <tree>" >&2; exit 2; }
cmd=${1:-}; base=${2:-}
[ -n "$base" ] || usage
shift 2
refs=refs/vm-batch/$$
gh=${KS_GH:-gh}; gate=${KS_BATCH_GATE:-"$(cd "$(dirname "$0")" && pwd)/vm.sh"}
root=$(git rev-parse --show-toplevel) || exit 2
fetch() { git -C "$root" fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" "$@" \
  || { echo "could not fetch $base $*" >&2; exit 2; }; }

if [ "$cmd" = landed ]; then
  tree=${1:-}; [ -n "$tree" ] || usage
  fetch
  sha=$(git -C "$root" rev-parse "origin/$base"); tip=$(git -C "$root" rev-parse "origin/$base^{tree}")
  if [ "$tip" = "$tree" ]; then echo "vm-batch landed: origin/$base $sha is the tested tree $tree"; exit 0; fi
  echo "vm-batch landed: origin/$base $sha has tree $tip, not the tested tree $tree"
  echo "gate the tip now: scripts/vm.sh origin/$base"; exit 1
fi
{ [ "$cmd" = check ] && [ $# -gt 0 ]; } || usage

repo=$($gh repo view --json nameWithOwner -q .nameWithOwner) || { echo "gh repo view failed" >&2; exit 2; }
prview() { $gh -R "$repo" pr view "$1" --json state,baseRefName,headRefOid -q '.state+" "+.baseRefName+" "+.headRefOid'; }
specs=""; seen=""
for n in "$@"; do
  case $n in ''|*[!0-9]*) usage;; esac
  case " $seen " in *" $n "*) echo "PR #$n given twice" >&2; exit 2;; esac
  seen="$seen $n"
  # shellcheck disable=SC2034 # h is read by eval
  read -r st b h <<< "$(prview "$n")"
  [ "$st" = OPEN ] && [ "$b" = "$base" ] || { echo "PR #$n is ${st:-unknown} on ${b:-unknown}, not open on $base" >&2; exit 2; }
  eval "head_$n=\$h"; specs="$specs +refs/pull/$n/head:$refs/pull/$n"
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/vm-batch.XXXXXX"); wt="$tmp/wt"; cache="$tmp/cache"; touch "$cache"
cleanup() {
  git -C "$root" worktree remove --force "$wt" 2>/dev/null; git -C "$root" worktree prune
  for n in $all; do git -C "$root" update-ref -d "$refs/pull/$n" 2>/dev/null; done
  rm -rf "$tmp"
}
all="$*"; trap cleanup EXIT
# shellcheck disable=SC2086
fetch $specs
bsha=$(git -C "$root" rev-parse "origin/$base")
for n in "$@"; do
  [ "$(git -C "$root" rev-parse "$refs/pull/$n")" = "$(eval "echo \$head_$n")" ] \
    || { echo "PR #$n: fetched head is not its headRefOid" >&2; exit 2; }
done
git -C "$root" worktree add -q --detach "$wt" "$bsha" || { echo "could not add the worktree" >&2; exit 2; }

gitm() { # git with a fixed identity, no signing, no hooks: the batch commits do not depend on user config
  GIT_AUTHOR_NAME=vm-batch GIT_AUTHOR_EMAIL=vm-batch@localhost GIT_COMMITTER_NAME=vm-batch \
    GIT_COMMITTER_EMAIL=vm-batch@localhost git -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
nth() { shift "$1"; echo "$1"; } # nth <k> <list...>
lbl() { local n; for n in "$@"; do printf ' #%s' "$n"; done; }
remaining=" $* "; excl=""; dropped=""
drop() { # drop <PR> <reason>
  remaining=${remaining/ $1 / }; excl="$excl #$1 ($2)"; dropped="$dropped $1"; eval "why_$1=\$2"
  echo "#$1 left out: $2"
}
build() { # build <PR...>: merges them onto the base in $wt; sets incl (merged) and shas (commit after each)
  local n; incl=""; shas=""
  git -C "$wt" checkout -q --detach "$bsha" || exit 2
  for n in "$@"; do
    if gitm -C "$wt" merge -q --no-ff --no-edit "$refs/pull/$n" >/dev/null 2>&1; then
      incl="$incl $n"; shas="$shas $(git -C "$wt" rev-parse HEAD)"
    else
      git -C "$wt" merge --abort 2>/dev/null || { echo "merging #$n failed (not a conflict)" >&2; exit 2; }
      drop "$n" conflicts
    fi
  done
}
gaterun() { # gaterun <sha> <label>: sets res to green|red; a tree is gated once
  local t rc; t=$(git -C "$root" rev-parse "$1^{tree}")
  res=$(awk -v t="$t" '$1 == t { print $2 }' "$cache")
  [ -z "$res" ] || return 0
  "$gate" "$1" >&2; rc=$?
  case $rc in 0) res=green;; 1) res=red;; *) echo "gate error (exit $rc) on $1" >&2; exit 2;; esac
  echo "$t $res" >> "$cache"; echo "gate $1 ($2): $res"
}

last=""
while :; do
  # shellcheck disable=SC2086
  build $remaining
  [ -n "$incl" ] || { last=""; break; }
  # shellcheck disable=SC2086
  set -- $incl
  last=$(nth $# $shas)
  # shellcheck disable=SC2086
  gaterun "$last" "$(lbl $incl | cut -c2-)"
  [ "$res" = red ] || break
  lo=1; hi=$# # smallest red prefix: prefix hi is red, prefix lo-1 green (the base for lo = 1)
  while [ "$lo" -lt "$hi" ]; do
    mid=$(( (lo + hi) / 2 ))
    # shellcheck disable=SC2086
    gaterun "$(nth "$mid" $shas)" "$(lbl $incl | cut -d' ' -f2-$((mid + 1)))"
    if [ "$res" = red ]; then hi=$mid; else lo=$((mid + 1)); fi
  done
  if [ "$hi" = 1 ]; then
    gaterun "$bsha" "base $base"
    [ "$res" = green ] || { echo "base $base itself is red"; echo "vm-batch: red, nothing green"; exit 1; }
  fi
  culprit=$(nth "$hi" "$@"); drop "$culprit" "red when #$culprit is added"
done
postdropped() {
  local n
  for n in $dropped; do
    $gh -R "$repo" pr comment "$n" --body "ci-local batch: not merged — $(eval "echo \"\$why_$n\"")" >/dev/null \
      || { echo "could not post on #$n" >&2; exit 3; }
  done
}
tip=$(git -C "$root" ls-remote origin "refs/heads/$base" | cut -f1)
[ "$tip" = "$bsha" ] || { echo "base $base moved ($bsha -> ${tip:-unknown}), gate again: not posting" >&2; exit 3; }
if [ -z "$last" ]; then
  postdropped
  [ -z "$excl" ] || echo "excluded:$excl"
  echo "vm-batch: red, nothing green"; exit 1
fi

# shellcheck disable=SC2086
set -- $incl
for n in "$@"; do
  [ "$(prview "$n" | cut -d' ' -f3)" = "$(eval "echo \$head_$n")" ] \
    || { echo "PR #$n head moved since the batch was built: not posting" >&2; exit 3; }
done
tree=$(git -C "$root" rev-parse "$last^{tree}")
order=""; for n in "$@"; do order="$order
#$n ($(eval "echo \$head_$n"))"; done
body="ci-local batch $last: green
base $base@$bsha
merge order:$order
tree $tree
Merge in this order with gh pr merge N --squash --delete-branch, then run scripts/vm-batch.sh landed $base $tree"
postdropped
for n in "$@"; do $gh -R "$repo" pr comment "$n" --body "$body" >/dev/null || { echo "could not post on #$n" >&2; exit 3; }; done
[ -z "$excl" ] || echo "excluded:$excl"
echo "vm-batch $last: green$(lbl "$@") tree $tree"
