# SCRBRD development checks

Preserve existing development work and validation documents. Work on a development
branch; do not merge main, push, install apps, or flash hardware without user approval.
Do not overwrite or implicitly incorporate the unmerged F13 branch. Keep F28 deferred.

## Automatic virtual checks

After changing mobile BLE transport/state, packet serialization, synchronization,
refresh/session ownership, fantasy delivery/navigation, or virtual fixtures/support,
automatically run `python3 tools/run_virtual_tests.py --quick` from this checkout.
Use its sibling firmware checkout; for an intentional development pair specify
`--firmware PATH` or `SCRBRD_FIRMWARE`. Never change companion branches silently.

Before reporting such code/test work ready to merge, run
`python3 tools/run_virtual_tests.py` (full Flutter suite, analysis, native regressions
and compatibility). Run it after the final relevant edits; do not repeatedly rerun
unchanged checks. For runner/path changes also run
`python3 -m unittest discover -s tools -p '*_test.py'`.
For unrelated mobile logic, run focused tests and the normal full Flutter checks as
appropriate. Documentation-only edits need inspection, not a mandatory full rebuild.

Read VIRTUAL_TESTING.md for setup and limitations. Missing companion/toolchain is a
reported verification limitation, not permission to skip checks silently or install
new dependencies. Plain flutter test skips native-backed cases without the bridge.
Inspect build/virtual-testing/report.txt and report failures/unexercised cases;
virtual results never establish radio/iOS restoration/display performance or F13
physical validation. Do not expand production architecture just for these checks.
