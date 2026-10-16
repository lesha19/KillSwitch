#!/bin/bash
# Runs the merge gate (scripts/ci-local.sh) inside the local tart macOS VM over ssh, never on this Mac:
# KillSwitch changes the network, so builds, tests and the app run only in the VM.
#   scripts/vm.sh <commit-or-ref> [--pr N]
# Exit code = the remote ci-local exit code; its last line ("ci-local <sha>: green|red at <step>") is shown.
# --pr N posts that line (plus the VM's macOS/Xcode) from this host with gh, after checking the PR head is
# the tested sha; if that lookup, the check or the post fails, exit 3. VM unreachable: exit 2.
# Env: KS_VM_SSH_CONFIG (default ~/vm/ssh_config), KS_VM_HOST (default ks-vm).
set -u
ref=${1:-}; pr=""
[ -n "$ref" ] || { echo "usage: $0 <commit-or-ref> [--pr N]" >&2; exit 2; }
if [ "${2:-}" = "--pr" ]; then
  pr=${3:-}; [ -n "$pr" ] || { echo "usage: $0 <commit-or-ref> [--pr N]: --pr needs a number" >&2; exit 2; }
fi
cfg=${KS_VM_SSH_CONFIG:-$HOME/vm/ssh_config}; host=${KS_VM_HOST:-ks-vm}
dir=/Users/admin/KillSwitch
sha=$(git rev-parse --verify "$ref^{commit}") || { echo "unknown ref: $ref" >&2; exit 2; }
vm() { ssh -F "$cfg" -o ConnectTimeout=10 -o BatchMode=yes "$host" "$@"; }

vm "git init -q $dir" || {
  echo "the VM is unreachable: start it with: tart run ks-base --no-graphics --vnc-experimental &" >&2; exit 2; }
GIT_SSH_COMMAND="ssh -F $cfg -o BatchMode=yes" git push -q -f "$host:$dir" "$sha:refs/ci/$sha" \
  || { echo "could not push $sha to the VM" >&2; exit 2; }

# Run this checkout's ci-local.sh (older PR branches predate it): copied to $dir/.gate/, it takes the VM
# repo as its root and adds its own clean worktree of the tested sha there.
vm "mkdir -p $dir/.gate && cat > $dir/.gate/ci-local.sh" < "$(dirname "$0")/ci-local.sh" \
  || { echo "could not copy ci-local.sh to the VM" >&2; exit 2; }
out=$(mktemp "${TMPDIR:-/tmp}/vm.XXXXXX"); trap 'rm -f "$out"' EXIT
vm "cd $dir && PATH=/opt/homebrew/bin:\$PATH bash .gate/ci-local.sh $sha" 2>&1 | tee "$out"
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
