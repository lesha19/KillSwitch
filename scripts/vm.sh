#!/bin/bash
# Runs the merge gate (scripts/ci-local.sh) inside the local tart macOS VM over ssh, never on this Mac:
# KillSwitch changes the network, so builds, tests and the app run only in the VM.
#   scripts/vm.sh <commit-or-ref> [--pr N | --only <test.sh>...]
# Exit code = the remote ci-local exit code; its last line ("ci-local <sha>: green|red at <step>") is shown.
# --pr N posts that line (plus the VM's macOS/Xcode) from this host with gh, after checking the PR head is
# the tested sha; if that lookup, the check or the post fails, exit 3. VM unreachable: exit 2.
# --only <test.sh>... runs just those Helper/tests files in the VM (no cores and with mihomo; no lint,
# xcodebuild or other steps) and the result line says "partial (only ...)": it is not a gate, so --pr
# with --only is refused (exit 2) and nothing is posted.
# Before the run it waits (scripts/wait-load.sh) for this Mac's load average to drop under KS_LOAD_MAX
# (default 20), at most KS_LOAD_WAIT seconds (default 600; 0 = no wait; skipped when KS_LOAD_WAITED=1,
# set by vm-batch.sh). A test that failed on a timing threshold is NOT rerun: a timing failure cannot be
# told from a logic one by its output (netbird 'up hangs' and vpn-on 'switch gap' are plain FAIL lines).
# The xcodebuild step is skipped when the diff of <ref> against the base (KS_GATE_BASE, default
# origin/master; the paths are sent to the VM, which has no base) touches no app files: see ci-local.sh.
# Env: KS_VM_SSH_CONFIG (default ~/vm/ssh_config), KS_VM_HOST (default ks-vm).
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
  echo "the VM is unreachable: start it with: tart run ks-base --no-graphics --vnc-experimental &" >&2; exit 2; }
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
vm "cd $dir && $cenv PATH=/opt/homebrew/bin:\$PATH bash .gate/ci-local.sh $sha${only:+ --only$only}" 2>&1 | tee "$out"
code=${PIPESTATUS[0]}
line=$(grep "^ci-local $sha: " "$out" | tail -n 1)

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
