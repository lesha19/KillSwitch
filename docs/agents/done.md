# Done and merge: KillSwitch

Read by the `done` skill first; these rules are stricter than it and win.

## The merge gate

GitHub Actions does not run (not paid): `gh pr checks` reports no checks, so nothing on GitHub stops a
merge. The gate is `scripts/ci-local.sh` (the ci.yml steps) run **inside the tart VM** by `scripts/vm.sh`;
never build, test or run the app on the host Mac (KillSwitch changes the network). One VM run at a time:
before starting one, make sure no other session is gating or building in the VM.

A PR is merged only with a green gate result posted on it for exactly what the base branch will hold.

## One PR

`scripts/vm.sh <head> --pr N` on a head that contains the base tip, then
`gh pr merge N --squash --delete-branch`. The squash commit keeps the tested tree.

## A batch of PRs (two or more, reviewed, waiting)

Gate them once instead of rebasing and re-gating each one after the previous merge:

1. `scripts/vm-batch.sh check <base> <PR> <PR>...` merges all PR heads, in that order, onto the base
   tip and gates that one commit in the VM. A PR that conflicts is left out; a red batch is bisected
   (gate runs on prefixes, one at a time) and the first PR that turns it red is left out, then the rest
   is gated again. Each green PR gets the comment `ci-local batch <sha>: green` with the order and tree;
   each left-out PR gets the reason.
2. Merge the green PRs **in the posted order**, one command each:
   `gh pr merge N --squash --delete-branch`. No other merges into the base in between: if one happens,
   or a PR head moves, the batch result no longer applies.
3. `scripts/vm-batch.sh landed <base> <tree>` (the line is in the comment). Exit 0 = the base tip is
   the tree that was gated. Exit 1 = it is not: gate the tip at once (`scripts/vm.sh origin/<base>`) and
   fix it before anything else is merged or released.

What is tested is the base tip after the whole batch; the commits between the squash merges are not
gated on their own. Release only from a tip that `landed` or `vm.sh` said is green.

## Before saying «готово»

The PR has a green gate comment (single or batch) for its merge, and after a batch `landed` said exit 0.
