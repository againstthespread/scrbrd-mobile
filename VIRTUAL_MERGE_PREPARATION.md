# Virtual integration merge preparation — 2026-10-17

Status: prepared locally for explicit approval; no main merge or push performed.
Both repositories use branch `codex/virtual-integration` in permanent worktrees:

- `~/Projects/_worktrees/scrbrd-virtual-firmware`
- `~/Projects/_worktrees/scrbrd-virtual-mobile`

Git `worktree move` relocated the original worktrees, including ignored build reports.
No branch recreation, reset, force checkout, or F13 integration was performed.

## Verification and limits

The complete runner passed all 18 steps after relocation, including 963 Flutter
tests (11 virtual scenarios), clean static analysis, native protocol compatibility,
seven existing Python native runners, and both standalone native C++ tests.
Five checkout-discovery regression tests pass separately. Both workflow files parse
as YAML; CI action/toolchain references were checked against public GitHub refs.
GitHub execution is not verified: no workflow was published or dispatched.

The full relocated run is preserved in the mobile worktree at
`build/virtual-testing/permanent-20261017/report.txt`, with logs/transcripts.
Earlier `build/virtual-testing/final` evidence remains preserved as historical
pre-relocation output; absolute paths recorded in those old reports are historical,
not runtime dependencies. Application source, BLE protocols and dependency files
are unchanged. F13 remains isolated at `49d5f0b` and F28 remains deferred.

## Approval-gated local merge sequence

Expected unchanged main revisions:

- Firmware: `fe254aaf6786f4a0f90b582e329c142776ea1555`
- Mobile: `07ccb26eb275df851fbab62d63b2ce17f3106bab`

Each repository has annotated local rollback reference
`rollback/main-before-virtual-integration-2026-10-17` at its original main.
After approval, first reverify both main working directories are clean and on main,
main still equals the expected revision, the source branch tips match the approved
commits, rollback tags resolve correctly, and main is an ancestor of the source.
Stop on unexpected changes/conflicts; preserve them and do not force/reset.

Then perform these local fast-forward merges, firmware first:

```sh
git -C "$HOME/Projects/scrbrd" merge --ff-only codex/virtual-integration
git -C "$HOME/Projects/scrbrd-mobile" merge --ff-only codex/virtual-integration
```

Verify both main tips equal the approved source tips and report final Git status.
These commands do not publish to GitHub; publishing requires separate approval.
Keep the permanent testing and all other development worktrees intact.

## CI rollout

Each new workflow runs the same full host-only suite against its changed repository
and companion main. Default CI needs the infrastructure published in both repos.
Once remote publication is separately approved, publish firmware first, mobile
second, and rerun any firmware bootstrap job that saw the old mobile main; or use
manual `companion_ref` after approved development-branch publication. Do not turn
an unavailable companion into a silently skipped passing check. No branch-protection
settings or remote configuration were changed in this task.
