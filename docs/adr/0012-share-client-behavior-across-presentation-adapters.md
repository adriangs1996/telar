---
status: accepted
---

# Share client behavior across presentation adapters

The TUI combined disposable client policy with terminal resources. A native
frontend would otherwise duplicate handlers, frame recovery, input ownership
and graphics retention. `telar-client` now owns that shared implementation;
`telar-frontend` remains its TUI adapter. Each connection owns an independent
model and resources. Sharing code does not synchronize focus or navigation.

Core remains the runtime/client value boundary. The common client depends on
core, never on backend, frontend, fonts, TTY resources or window APIs. Its shared
memory catalog is a guarded POSIX media resource, not a terminal service. Input
routing accepts semantic events; the TUI supplies terminal decoding. Geometry
is explicit and versioned. Native chrome need not use terminal cells.

Presentation borrows a projection synchronously, then retains its own bounded
work. One client-owned token identifies one in-flight delivery. Only successful
completion reaches the shared delivery handler. The model filters attachment
generations before deriving ACKs, and exact frame matching preserves newer
damage. Graphics leases keep retired allocations charged until consumers finish.
The TUI keeps its output buffers, partial-write ordering, pacing and Kitty
implementation. No new frame queue or execution model accompanies this split.

The alternative of sharing only a draw interface left host input, geometry and
services coupled to the TUI. Moving client state into core weakened runtime
ownership. A common widget framework would prescribe a GUI before one exists.
Narrow host ports and a controllable headless presentation adapter test the
actual shared handlers without any of those changes.

This refines [presentation by versions](0007-drive-client-presentation-from-model-versions.md)
and preserves [controller/handler separation](0006-separate-request-controllers-from-command-handlers.md).
The native renderer and any event-loop rewrite remain separate work. Performance
acceptance follows the measured gates, not the architectural decision.
