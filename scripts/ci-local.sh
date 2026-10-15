#!/bin/bash
# The merge gate: what .github/workflows/ci.yml does, run on this Mac (Actions is not paid) on a clean
# detached worktree of one commit. Stops at the first failing step; the log is kept on red.
#   scripts/ci-local.sh <commit-or-ref> [--pr N]
# Last line: "ci-local <sha>: green" or "ci-local <sha>: red at <step>"; exit 0 / 1.
# --pr N also posts that line to the PR with gh, after checking the PR head is the tested sha;
# if that lookup, the check or the post fails, exit 3 (even when the tests were green).
set -u
ref=${1:-}; pr=""
[ -n "$ref" ] || { echo "usage: $0 <commit-or-ref> [--pr N]" >&2; exit 2; }
if [ "${2:-}" = "--pr" ]; then
  pr=${3:-}; [ -n "$pr" ] || { echo "usage: $0 <commit-or-ref> [--pr N]: --pr needs a number" >&2; exit 2; }
fi
root=$(cd "$(dirname "$0")/.." && pwd)
sha=$(git -C "$root" rev-parse --verify "$ref^{commit}") || { echo "unknown ref: $ref" >&2; exit 2; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ci-local.XXXXXX")
wt="$tmp/src"; log="$tmp/ci-local.log"; failed=""; start=$(date +%s)
cleanup() {
  git -C "$root" worktree remove --force "$wt" 2>/dev/null
  git -C "$root" worktree prune
  rm -rf "$tmp/build"
  [ -n "$failed" ] || rm -rf "$tmp"
}
trap cleanup EXIT
git -C "$root" worktree add -q --detach "$wt" "$sha" || { echo "could not add the worktree" >&2; exit 2; }
echo "log: $log"

step() { # step <name> <command...>: output to the log, tail on failure
  local name=$1; shift
  echo "== $name"; echo "== $name" >> "$log"
  if (cd "$wt" && "$@") >> "$log" 2>&1; then return 0; fi
  tail -n 40 "$log"; failed=$name; return 1
}
lint() {
  local f
  for f in Helper/ks Helper/*.sh Helper/tests/*.sh scripts/*.sh; do bash -n "$f" || return 1; done
  shellcheck -S warning Helper/ks Helper/*.sh scripts/*.sh
}
mihomo_tests() { # ci.yml "Fetch mihomo" + "Helper tests": with the core when it can be fetched
  local m=/nonexistent/mihomo t fails=0
  if Helper/fetch-mihomo.sh; then m=$PWD/Helper/mihomo
  else echo "warning: mihomo could not be fetched: the helper tests skip the mihomo -t and controller checks"; fi
  for t in Helper/tests/*.sh; do
    echo "== $t"
    MIHOMO=$m bash "$t" || fails=$((fails + 1))
  done
  [ "$fails" = 0 ]
}
versions() {
  xcodegen --version | grep -q '2\.46\.0' || echo "warning: xcodegen is not 2.46.0 (CI pins it)"
  shellcheck --version | grep -q '^version: 0\.11\.0' || echo "warning: shellcheck is not 0.11.0 (CI pins it)"
  return 0
}

{ step "lint" lint \
  && step "tool versions" versions \
  && step "xcodegen" xcodegen generate \
  && step "xcodebuild build test" xcodebuild -quiet -project KillSwitch.xcodeproj -scheme KillSwitch \
       -destination 'platform=macOS' -derivedDataPath "$tmp/build" CODE_SIGNING_ALLOWED=NO build test \
  && step "test-helper-ci" scripts/test-helper-ci.sh \
  && step "helper tests with mihomo" mihomo_tests \
  && step "test-filter-trust" scripts/test-filter-trust.sh; } || true

grep "^warning:" "$log" 2>/dev/null
secs=$(( $(date +%s) - start ))
if [ -z "$failed" ]; then line="ci-local $sha: green"; else line="ci-local $sha: red at $failed"; echo "log kept: $log"; fi
echo "$line"

prfail=0
if [ -n "$pr" ]; then
  repo=$(cd "$root" && gh repo view --json nameWithOwner -q .nameWithOwner) || repo=""
  head=""; [ -z "$repo" ] || head=$(gh -R "$repo" pr view "$pr" --json headRefOid -q .headRefOid)
  if [ "$head" != "$sha" ]; then
    echo "PR #$pr head is ${head:-unknown}, not $sha: not posting" >&2; prfail=1
  else
    gh -R "$repo" pr comment "$pr" --body "$line
macOS $(sw_vers -productVersion), $(xcodebuild -version | tr '\n' ' '), ${secs}s" || { echo "could not post the comment" >&2; prfail=1; }
  fi
fi
[ "$prfail" = 0 ] || exit 3
[ -z "$failed" ]
