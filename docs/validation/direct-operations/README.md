# Direct client operations

Validated locally on macOS arm64 with Zig 0.16.0, on branch
`refactor/client-world-storage`. This records the first operation migration;
the completed global migration is recorded in
[global-direct-operations](../global-direct-operations/README.md).

## Changed behavior paths

Configured action routing now checks prompt ownership and calls native, Lua or
plugin execution directly. Native dispatch owns its copy-mode preflight.
Successful pane openings consume correlation and select the concrete operation
with a switch. Request failures select recovery before notification, without
an erased recovery or reporting callback table.

`pane_splits` keeps request, successful confirmation and resize recovery
together. Provisional geometry precedes creation. Confirmation validates the
runtime identity before committing; a delivery error preserves the accepted
creation. Inactive and retired tabs retain their detach/reconciliation policy.
A stale reply cannot detach an identity represented in the current model.

The host-resource simplification is recorded separately in
[host-flow-simplification](../host-flow-simplification/README.md).

## Validation

| Check | Result |
| --- | --- |
| `zig build test-client` | 933 passed |
| `zig build test-frontend` | 607 passed |
| `zig build test-gui` | 746 passed |
| `zig build check-client-boundaries` | Passed, including 19 checker tests |
| `zig build codestyle` | Passed |
| `zig build` | Passed, 51/51 steps |
| `git diff --check` | Passed |

Total client/TUI/GUI tests: 2,286. Commands used the Homebrew Python on PATH.
An intermediate boundary check caught a deleted type still listed in
`capabilities.json`; that entry was removed and the boundary/client checks
passed afterwards. Frontend and GUI checks passed on the same final code.

The removed handler/effects fixtures no longer define public APIs. Existing
integration coverage remains, with new checks using concrete clients for:

- GUI input admission → `update` → horizontal split request → correlated
  server event → `update` → attached and focused right-hand pane.
- Concurrent split suppression without layout or identity mutation.
- Original-size restoration after request identity exhaustion.
- Invalid reply rejection before model mutation or outbound work.
- Commit retention after geometry delivery failure.
- Protection against detaching a represented identity in a late reply.
- Recovery failure consuming correlation without notification.
- Explicit editor split target and launch arguments despite different focus.
- One workspace fallback retry after a remembered pane disappears, followed
  by fatal failure if that retry also fails.
- Prompt suppression across native, Lua callback, Lua expression and plugin
  action sources.

Existing tests exercise inactive/retired tabs, canonical target retirement,
copy mode, Lua semantic keys and paste, notifications, attachment recovery,
tab recovery and plugin completion. No performance improvement is inferred
from this structural change. No live runtime, native window or external agent
was launched for this validation.
