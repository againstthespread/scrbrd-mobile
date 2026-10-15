# F29 — runtime lifetime and logical Bluetooth ownership

## Runtime lifetime (first commit)

The app root created a provider repository on every build while the connection
screen's coordinators retained the original repository. A second confirmed defect
allowed an outstanding fantasy observation to notify/send after disposal.

Regressions were added before implementation: both failed in
`build/f29-lifetime-before.log` (the failed widget test also left cleanup timers,
causing one cascading failure). The same tests pass after the fix.

The app state now owns one repository for its lifetime. Factory-created sources
are explicitly owned and closed once; injected sources and HTTP clients remain
borrowed. The connection screen consistently uses its initial dependency graph;
replace its widget key when intentionally creating another runtime. Disposal
invalidates startup/fantasy work. Projection callbacks from an older generation
or disposed coordinator cannot schedule a display refresh.

Validation at this commit: 171 focused tests passed, including late projections,
resource ownership, disposal during observation, H01 foreground recovery and desired
content recovery. Static analysis: no issues. Protocol and lifecycle foreground /
background behavior are unchanged. Final full-suite and iOS results follow in the
logical ownership commit.
