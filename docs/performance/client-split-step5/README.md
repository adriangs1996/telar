# Client split, phase 5

The TUI now uses `telar-client.presentation` for its borrowed projection,
observed/prepared/delivered revisions, bounded submission and completion token.
Output retains a token instead of a second acknowledgement batch. Successful
host write completion is still the TUI's delivery boundary. Composition, diff,
Kitty output and pacing remain in `telar-frontend`.

The shared pane model captures presentation commits, including fullscreen-hidden
panes. The application derives ACKs only from accepted commits. Local attachment
generations prevent a delayed completion from acknowledging a reconstructed or
reattached pane that happens to reuse a wire frame ID. Token identity separately
rejects duplicate, failed, cancelled and replaced presentation work.

The headless adapter owns a bounded cell copy and has controllable admission and
completion. Its integration fixture uses the shared decoded-message entrypoint,
workspace/frame/input/resource/presentation handlers, model and outbox. Unsupported
fixture capabilities fail explicitly; this is not a second complete CLI.

Proof includes:

- Input uses the newest child modes while an older presentation remains in flight.
- Reusing decoded wire storage and replacing model buffers cannot change retained
  presentation cells.
- Bad patch bases request a snapshot without advancing the model.
- Failures, cancellation and stale completions preserve pending damage and ACKs.
- Reattachment and workspace reconstruction reject old frame identities.
- Geometry ABA differs from the delivered pane-coordinate authority.
- Released graphics credit precedes the cell ACK; retained bytes stay charged.
- Two independent assemblies produce equivalent state and requests.
- Steady-state frame application, preparation, completion and semantic input make
  no allocator calls, checked with an armed failing allocator.
- The 16,384-cell headless limit fails explicitly instead of truncating output.
- A TUI integration test checks successful and failed host-write completion.

## Validation

On the phase-0 host and Zig 0.16.0:

- ReleaseSafe: 774 common-client tests and 712 frontend tests passed.
- Debug: 774 common-client tests passed.
- ReleaseSafe semantic check passed.
- Diagnostics-enabled ReleaseFast production build passed.
- Common-client codestyle and `git diff --check` passed.

Commands were the existing `test-client`, `test-frontend`, `check`, production
build and `codestyle` targets. `tests.log` and `debug.log` retain suite summaries.
The first headless test attempt incorrectly popped unclaimed outbox sends; its
assertions caught the fixture error. Tests now use `beginSend` and `finishSend`.

No paired performance acceptance, physical graphics measurement or native
renderer claim is made here. Phase 6 still owns the dependency audit, full
contract suites, end-to-end checks and repeated paired measurements. The
intermittent two-client pointer-shape assertion recorded in phase 2 remains an
open final-gate item.

The lifecycle, bounds and adapter responsibilities are recorded in
`src/client/presentation/README.md`.
