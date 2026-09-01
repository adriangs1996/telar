# Client layout persistence

This flow retains client-owned layout across a detach without turning it into
runtime authority. The client remains the only process that mutates sidebar
geometry, workspace-list collapse, active tab and pane focus, fullscreen state,
and split axes or ratios. The runtime keeps a bounded replica only for the next
client attached to the same terminal.

## Identity and bounds

At startup, the frontend derives a stable terminal identity from emulator
session variables or the host TTY. `request_runtime_state` subscribes the
connection with that identity before any layout update is accepted.

The runtime preallocates eight records before entering its event loop. Each
record holds at most 64 tab layouts and 127 tree nodes in total. Least-recently
used identity replacement bounds disconnected state. There is no disk write;
stopping the server discards every record.

## Update path

```text
completed client event
        |
client_layouts.observe
        |
fixed-size version comparison
        |
update_client_layout
        |
runtime request dispatcher
        |
ClientLayoutStore.replace
        |
validate pane sets against runtime authority
        |
merge current workspace into retained terminal record
```

The client serializes only tabs whose canonical runtime snapshot has loaded.
The outbox owns the encoded bytes and coalesces adjacent obsolete layouts. It
never folds across an ordered request that can change pane membership. If its
two layout slots are occupied, the latest semantic version remains unsent and
the next completed send retries it. The steady-state path allocates nothing.
An explicit detach captures once before retiring pane attachments, including
layout mutations decoded in the same host-input batch.

The runtime rejects malformed trees at schema decode and ignores an update
whose active tab no longer matches authoritative workspace and pane state. It
prunes stale inactive layouts and merges valid current-workspace tabs, leaving
other visited workspaces available for later handoff.

## Reconnect path

`client_layout_snapshot` is the first runtime-state projection delivered after
subscription. The client applies it before registering `initial_open`:

1. restore sidebar visibility and preferred width;
2. restore workspace-list collapse and per-workspace navigation history;
3. cache every validated split tree by complete tab identity;
4. attach the retained active pane using geometry derived from restored chrome;
5. consume each cached tree when the matching canonical tab snapshot arrives.

Pane membership stays authoritative in the runtime. If it changed while the
client was detached, the stale tree is omitted and reconciliation uses canonical
pane order. Chrome preferences still restore even when no split tree remains
safe. A narrower host clamps only presentation geometry and preserves the
preferred sidebar width for later expansion.

## Proof

- `runtime retains a terminal layout across client reconnection` crosses two
  real frontend connections and one live runtime.
- `restored client layout controls the initial attach geometry` proves startup
  ordering and restored navigation.
- `sidebar preferences survive when retained pane layouts become stale` proves
  chrome recovery without a valid active tree.
- Schema corpus, workspace layout, outbox ownership and event-observation tests
  prove bounded encoding, split-tree reconstruction, causal coalescing and
  duplicate suppression.
