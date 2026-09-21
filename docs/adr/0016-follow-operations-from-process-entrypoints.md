---
status: accepted
---

# Follow operations from process entrypoints

The mandatory controller, handler, erased executor and effects layers made
Telar's operations difficult to follow from its event loops. We replace that
requirement with direct calls from each process dispatch to operation modules
that keep request, completion and recovery together. This supersedes ADR 0006;
the runtime/client ownership split, commit ordering, bounded asynchronous work
and failure contracts remain requirements.

Ports belong at actual implementation boundaries such as GUI/TUI and OS
services. Internal operations use concrete state and ordinary functions.
Tests exercise their behavior through those boundaries rather than requiring
another callback layer solely to replace the implementation. Migration is by
complete flow, including its failure paths and obsolete code, with progress
recorded in the entrypoint map.
