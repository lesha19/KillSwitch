#!/bin/bash
# The merge gate: what .github/workflows/ci.yml does, run on this Mac (Actions is not paid) on a clean
# detached worktree of one commit. Stops at the first failing step; the log is kept on red.
#   scripts/ci-local.sh <commit-or-ref> [--pr N | --only <test.sh>... | --part host|vm]
# Last line: "ci-local <sha>: green" or "ci-local <sha>: red at <step>"; exit 0 / 1.
# --pr N also posts that line to the PR with gh, after checking the PR head is the tested sha;
# if that lookup, the check or the post fails, exit 3 (even when the tests were green).
# --only runs just the listed Helper/tests files (names or paths), without cores and with mihomo, and
# nothing else: not a gate. The last line says "partial (only ...)" and --pr is refused with it.
# --part host runs only the steps that do not touch the system (lint, tool versions, xcodegen, xcodebuild
# build test: the app tests read sources and use mocks, no installed app, service, pf or keychain), --part
# vm the rest (test-helper-ci, helper tests with mihomo, test-filter-trust, test-vm-batch). scripts/vm.sh runs
# the host part on this Mac and the vm part in the VM at once; each says "host part"/"vm part" in its last
# line, which is not a gate result (--pr is refused). Without --part everything runs here, as before.
# The xcodebuild step is skipped ("skip: no app changes") when the commit's diff against the base touches
# only docs, scripts (not release.sh), the changelog/readme/licence, .github and Helper/tests (see
# app_changes); any doubt (no base, a diff error, an unknown path) builds. The base is KS_GATE_BASE
# (default origin/master); KS_CHANGED_FILE names a file with the changed paths, one per line, which
# scripts/vm.sh sends because the VM repo has no base.
# xcodebuild build test compiles only this Mac's architecture (ONLY_ACTIVE_ARCH=YES, ARCHS=$(uname -m)) and
# writes no index store; KS_GATE_UNIVERSAL=1 restores the x86_64+arm64 build. scripts/release.sh is
# unchanged and still builds universal. The line "time xcodebuild build test: Ns" in the output gives the step time.
set -u
usage="usage: $0 <commit-or-ref> [--pr N | --only <test.sh>... | --part host|vm]"
ref=${1:-}; pr=""; only=(); part=""
[ -n "$ref" ] || { echo "$usage" >&2; exit 2; }
shift
while [ $# -gt 0 ]; do
  case $1 in
    --pr) pr=${2:-}; [ -n "$pr" ] || { echo "$usage: --pr needs a number" >&2; exit 2; }; shift 2;;
    --part) part=${2:-}; case $part in host|vm) ;; *) echo "$usage: --part is host or vm" >&2; exit 2;; esac; shift 2;;
    --only) shift; [ $# -gt 0 ] || { echo "$usage: --only needs files" >&2; exit 2; }
      only=("$@"); break;;
    *) echo "$usage" >&2; exit 2;;
  esac
done
if [ -n "$pr" ] && { [ ${#only[@]} -gt 0 ] || [ -n "$part" ]; }; then
  echo "--pr with --only/--part: a partial run is not a gate, nothing is posted" >&2; exit 2; fi
if [ -n "$part" ] && [ ${#only[@]} -gt 0 ]; then echo "$usage: --part with --only" >&2; exit 2; fi
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
files=("$wt"/Helper/tests/*.sh); files=("${files[@]#"$wt"/}") # the test files this run covers
partial=""
[ -z "$part" ] || partial="$part part "
if [ ${#only[@]} -gt 0 ]; then
  files=()
  for f in "${only[@]}"; do
    f=${f#Helper/tests/}; f=${f%.sh}; f=Helper/tests/$f.sh
    [ -f "$wt/$f" ] || { echo "no such test in $sha: $f" >&2; exit 2; }
    files+=("$f")
  done
  partial="partial (only ${files[*]#Helper/tests/}) "
fi

step() { # step <name> <command...>: output to the log, tail on failure
  local name=$1 t0=$SECONDS from; shift
  echo "== $name"; echo "== $name" >> "$log"; from=$(wc -l < "$log")
  if (cd "$wt" && "$@") >> "$log" 2>&1; then
    tail -n +$((from + 1)) "$log" | grep '^time ' # per-test times a step reports
    echo "time $name: $((SECONDS - t0))s"; return 0
  fi
  tail -n 40 "$log"; failed=$name; return 1
}
lint() {
  local f
  for f in Helper/ks Helper/*.sh Helper/tests/*.sh scripts/*.sh; do bash -n "$f" || return 1; done
  shellcheck -S warning Helper/ks Helper/*.sh scripts/*.sh
}
mihomo_tests() { # ci.yml "Fetch mihomo" + "Helper tests": with the core when it can be fetched
  local m=/nonexistent/mihomo out t n fails=0
  if Helper/fetch-mihomo.sh; then m=$PWD/Helper/mihomo
  else echo "warning: mihomo could not be fetched: the helper tests skip the mihomo -t and controller checks"; fi
  out=$(mktemp -d "$tmp/mihomo.XXXXXX")
  # 4 at a time, as scripts/test-helper-ci.sh runs the same files
  printf '%s\0' "${files[@]}" | /usr/bin/xargs -0 -P 4 -I{} bash -c \
    'n=$(basename "$1" .sh); s=$SECONDS; MIHOMO="$3" bash "$1" > "$2/$n.out" 2>&1; echo $? > "$2/$n.rc"
     echo "time   $1: $((SECONDS - s))s" > "$2/$n.time"' _ {} "$out" "$m"
  sort -t: -k2 -rn "$out"/*.time | head -5 # the slowest files
  for t in "${files[@]}"; do # a file with no exit status (killed, never run) fails too
    n=$(basename "$t" .sh)
    [ "$(cat "$out/$n.rc" 2>/dev/null)" = 0 ] && continue
    fails=$((fails + 1)); echo "== $t"; cat "$out/$n.out" 2>/dev/null || echo "no result: it did not finish"
  done
  [ "$fails" = 0 ]
}
app_changes() { # 0 = the app build may differ from the base (or we cannot tell), 1 = it cannot
  local list f
  if [ -n "${KS_CHANGED_FILE:-}" ]; then list=$(cat "$KS_CHANGED_FILE") || return 0
  else list=$(git -C "$root" diff --name-only "${KS_GATE_BASE:-origin/master}...$sha" 2>/dev/null) || return 0; fi
  [ -n "$list" ] || return 0 # an empty diff is a doubt, not a proof
  while IFS= read -r f; do
    case $f in
      scripts/release.sh) return 0;; # Tests/CLITests.swift reads it
      docs/*|scripts/*|.github/*|Helper/tests/*|Helper/*.md|CHANGELOG.md|README.md|CONTEXT.md|LICENSE|.gitignore|.gitleaks.toml) ;;
      *) return 0;;
    esac
  done <<< "$list"
  return 1
}
build_test() {
  if app_changes; then
    # One architecture (this Mac's) instead of x86_64+arm64: the tests run natively and only here, so the
    # other slice would be compiled for nothing; the universal build stays in release.sh (archive).
    # No index store: nothing reads it. KS_GATE_UNIVERSAL=1 puts the universal build back.
    local arch; arch=$(uname -m)
    local flags=(ONLY_ACTIVE_ARCH=YES "ARCHS=$arch" COMPILER_INDEX_STORE_ENABLE=NO)
    [ "${KS_GATE_UNIVERSAL:-}" = 1 ] && flags=(ONLY_ACTIVE_ARCH=NO COMPILER_INDEX_STORE_ENABLE=NO)
    step "xcodebuild build test" xcodebuild -quiet -project KillSwitch.xcodeproj -scheme KillSwitch \
      -destination "platform=macOS,arch=$arch" -derivedDataPath "$tmp/build" CODE_SIGNING_ALLOWED=NO \
      "${flags[@]}" build test
  else echo "skip: no app changes (xcodebuild build test)"; fi
}
versions() {
  xcodegen --version | grep -q '2\.46\.0' || echo "warning: xcodegen is not 2.46.0 (CI pins it)"
  shellcheck --version | grep -q '^version: 0\.11\.0' || echo "warning: shellcheck is not 0.11.0 (CI pins it)"
  return 0
}

host_steps() { # what does not touch the system: safe on the operator's Mac
  step "lint" lint \
    && step "tool versions" versions \
    && step "xcodegen" xcodegen generate \
    && build_test
}
vm_steps() { # what changes the network, pf, DNS or a service: a clean system only
  step "test-helper-ci" scripts/test-helper-ci.sh \
    && step "helper tests with mihomo" mihomo_tests \
    && step "test-filter-trust" scripts/test-filter-trust.sh \
    && { if [ -f "$wt/scripts/test-vm-batch.sh" ]; then step "test-vm-batch" scripts/test-vm-batch.sh
         else echo "skip: no scripts/test-vm-batch.sh in this tree"; fi; }
}
if [ ${#only[@]} -gt 0 ]; then
  { step "test-helper-ci" env KS_ONLY="${files[*]}" scripts/test-helper-ci.sh \
    && step "helper tests with mihomo" mihomo_tests; } || true
elif [ "$part" = host ]; then host_steps || true
elif [ "$part" = vm ]; then vm_steps || true
else { host_steps && vm_steps; } || true
fi

grep "^warning:" "$log" 2>/dev/null
secs=$(( $(date +%s) - start ))
if [ -z "$failed" ]; then line="ci-local $sha: ${partial}green"; else line="ci-local $sha: ${partial}red at $failed"; echo "log kept: $log"; fi
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
