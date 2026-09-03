# Agent command history

Agent commands enter history through native harness hooks or a trusted proxy
tap plugin. Both sources use the runtime-owned history service; neither writes
SQLite or emits history protocol messages directly.

```text
native hook report                 proxy tap effect
        |                                  |
        `-------------+--------------------'
                      |
                      v
        history.Service.recordAgentCommand
                      |
          filter secrets and policies
                      |
          allocate one owned request
                      |
                      v
          bounded history worker queue
                      |
                      v
          ensure synthetic session exists
                      |
          INSERT OR IGNORE command
                      |
              SQLite command table
```

Agent records carry an `origin`, `provider` and optional `tool_call_id`.
`tool_call_id` is unique within a session when present, so duplicate hook or
plugin delivery cannot create duplicate rows. A non-pane record may synthesize
its parent session because hooks can arrive before terminal command detection.

Secret filtering is enabled unless the trusted source explicitly disables
redaction. Unlike pane capture, leading whitespace is not a suppression signal
for agent records because it is ordinary structured input rather than an
interactive shell privacy convention.

Queries return `origin` and `provider` over schema generation 33. The CLI keeps
the existing `[agent]` author marker and renders a non-empty provider before the
command, allowing users to distinguish native and plugin observations without
exposing the tool-call identifier.
