#!/bin/bash
# Runs the merge gate (scripts/ci-local.sh) in two parts at once. In the local tart macOS VM over ssh runs
# everything that changes the network, pf, DNS or a service (test-helper-ci, helper tests with mihomo,
# test-filter-trust, test-vm-batch: --part vm). On this Mac, in a clean worktree of the commit with its own
# derived data in a temp folder, runs lint, xcodegen and xcodebuild build test (--part host): the app tests
# read sources and use mocks, they never touch an installed KillSwitch, its service, pf or the keychain, and
# nothing is installed or started here. KS_VM_ONLY=1 puts the whole gate back into the VM.
#   scripts/vm.sh <commit-or-ref> [--pr N | --only <test.sh>...]
# Exit code 0 = both parts green, 1 = either is red; the last line is "ci-local <sha>: green|red at <step>"
# (the host part's step wins when both are red, as it comes first in the gate order).
# --pr N posts that line (plus the VM's macOS/Xcode) from this host with gh, after checking the PR head is
# the tested sha; if that lookup, the check or the post fails, exit 3. VM unreachable: exit 2.
# --only <test.sh>... runs just those Helper/tests files in the VM (no cores and with mihomo; no lint,
# xcodebuild or other steps; the host part does not run) and the result line says "partial (only ...)": it is not a gate, so --pr
# with --only is refused (exit 2) and nothing is posted.
# Before the run it waits (scripts/wait-load.sh) for this Mac's load average to drop under KS_LOAD_MAX
# (default 20), at most KS_LOAD_WAIT seconds (default 600; 0 = no wait; skipped when KS_LOAD_WAITED=1,
# set by vm-batch.sh). A test that failed on a timing threshold is NOT rerun: a timing failure cannot be
# told from a logic one by its output (netbird 'up hangs' and vpn-on 'switch gap' are plain FAIL lines).
# The xcodebuild step is skipped when the diff of <ref> against the base (KS_GATE_BASE, default
# origin/master; the paths are sent to the VM, which has no base) touches no app files: see ci-local.sh.
# Env: KS_VM_SSH_CONFIG (default ~/vm/ssh_config), KS_VM_HOST (default ks-vm): which VM of the pool
# (ks-vm = ks-base, ks-vm2 = ks-vm2, one ssh_config host each). Callers that serialize runs hold one lock
# per VM, /tmp/<KS_VM_HOST>.lock (mkdir: /tmp/ks-vm.lock, /tmp/ks-vm2.lock), so different VMs run at once.
set -u
usage="usage: $0 <commit-or-ref> [--pr N | --only <test.sh>...]"
ref=${1:-}; pr=""; only=""
[ -n "$ref" ] || { echo "$usage" >&2; exit 2; }
case ${2:-} in
  "") ;;
  --pr) pr=${3:-}; [ -n "$pr" ] && [ $# -eq 3 ] || { echo "$usage: --pr needs a number" >&2; exit 2; };;
  --only) [ $# -ge 3 ] || { echo "$usage: --only needs files" >&2; exit 2; }
    shift 2; only=$(printf ' %q' "$@");;
  *) echo "$usage" >&2; exit 2;;
esac
cfg=${KS_VM_SSH_CONFIG:-$HOME/vm/ssh_config}; host=${KS_VM_HOST:-ks-vm}
dir=/Users/admin/KillSwitch
sha=$(git rev-parse --verify "$ref^{commit}") || { echo "unknown ref: $ref" >&2; exit 2; }
vm() { ssh -F "$cfg" -o ConnectTimeout=10 -o BatchMode=yes "$host" "$@"; }

[ "${KS_LOAD_WAITED:-}" = 1 ] || "$(dirname "$0")/wait-load.sh"
vm "git init -q $dir" || {
  echo "the VM is unreachable: start it with: tart run <the tart VM of $host> --no-graphics --vnc-experimental &" >&2; exit 2; }
GIT_SSH_COMMAND="ssh -F $cfg -o BatchMode=yes" git push -q -f "$host:$dir" "$sha:refs/ci/$sha" \
  || { echo "could not push $sha to the VM" >&2; exit 2; }

# Run this checkout's ci-local.sh (older PR branches predate it): copied to $dir/.gate/, it takes the VM
# repo as its root and adds its own clean worktree of the tested sha there.
vm "mkdir -p $dir/.gate && cat > $dir/.gate/ci-local.sh" < "$(dirname "$0")/ci-local.sh" \
  || { echo "could not copy ci-local.sh to the VM" >&2; exit 2; }
# the paths this commit changes against the base: ci-local skips xcodebuild when none is an app file
cenv=""
if git diff --name-only "${KS_GATE_BASE:-origin/master}...$sha" 2>/dev/null | vm "cat > $dir/.gate/changed.txt"; then
  cenv="KS_CHANGED_FILE=$dir/.gate/changed.txt"
else vm "rm -f $dir/.gate/changed.txt"; fi
out=$(mktemp "${TMPDIR:-/tmp}/vm.XXXXXX"); trap 'rm -f "$out"' EXIT
split=1; partarg=" --part vm"; { [ -n "$only" ] || [ "${KS_VM_ONLY:-}" = 1 ]; } && { split=0; partarg=""; }
hout=""; hpid=""
if [ "$split" = 1 ]; then # the host part starts now and runs while the VM works
  hout=$(mktemp "${TMPDIR:-/tmp}/vm-host.XXXXXX"); trap 'rm -f "$out" "$hout"' EXIT
  nice -n 10 bash "$(dirname "$0")/ci-local.sh" "$sha" --part host > "$hout" 2>&1 &
  hpid=$!
fi
vm "cd $dir && $cenv PATH=/opt/homebrew/bin:\$PATH bash .gate/ci-local.sh $sha${only:+ --only$only}$partarg" 2>&1 | tee "$out"
code=${PIPESTATUS[0]}
line=$(grep "^ci-local $sha: " "$out" | tail -n 1)
if [ "$split" = 1 ]; then
  wait "$hpid"; hcode=$?
  echo "---- host part (this Mac) ----"; cat "$hout"
  hline=$(grep "^ci-local $sha: " "$hout" | tail -n 1)
  if [ "$code" -gt 1 ] || [ "$hcode" -gt 1 ]; then code=2 # a gate error, not a verdict
  elif [ "$code" = 1 ] || [ "$hcode" = 1 ]; then code=1; else code=0; fi
  if [ "$code" = 2 ]; then line=""
  elif [ "$hcode" = 1 ]; then line="ci-local $sha: red at ${hline##*red at }"
  elif [ "$code" = 1 ]; then line="ci-local $sha: red at ${line##*red at }"
  else line="ci-local $sha: green"; fi
  [ -z "$line" ] || echo "$line"
fi

prfail=0
if [ -n "$pr" ]; then
  repo=$(gh repo view --json nameWithOwner -q .nameWithOwner) || repo=""
  head=""; [ -z "$repo" ] || head=$(gh -R "$repo" pr view "$pr" --json headRefOid -q .headRefOid)
  if [ "$head" != "$sha" ] || [ -z "$line" ]; then
    echo "PR #$pr head is ${head:-unknown}, not $sha (or no result line): not posting" >&2; prfail=1
  else
    env=$(vm 'echo "macOS $(sw_vers -productVersion), $(/usr/bin/xcodebuild -version | head -n 1)"') || env="macOS ?"
    gh -R "$repo" pr comment "$pr" --body "$line
(in VM: $env)" || { echo "could not post the comment" >&2; prfail=1; }
  fi
fi
[ "$prfail" = 0 ] || exit 3
exit "$code"
