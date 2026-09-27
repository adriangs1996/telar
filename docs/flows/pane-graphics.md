# Pane graphics

Pane graphics carry image resources and placements from the runtime's terminal
emulator to the window. The runtime owns the canonical image identity,
generation, pixels and placement facts. The disposable client owns its
retained replica of resources and placements, their quotas and the semantic
cell fallback flag.

## PNG ingestion

A child's `a=T,f=100` command enters through its PTY output. The interactive
terminal ignores graphics APCs; the pane queues the same bytes for the media
actor. `media.Processor.processMedia` feeds Ghostty's stream, which owns base64
chunk assembly, command semantics, replies and placements. The media pipeline
installs `sys.decode_png` once before parsing, and the callback delegates PNG
decoding to Wuffs with the supplied quota allocator. It returns RGBA pixels,
not a second graphics protocol representation.

Decoded resources follow the existing `graphics_image`, pixel transfer and
`graphics_placement` messages. No IPC format changes. Images and placements
survive client disconnection; snapshot recovery rebuilds their client replica.
Malformed PNGs and allocation failures leave no committed image and follow
Ghostty's normal error replies, including `q=2` suppression. Decoder buffers
and partial output are freed on failure. Media queue overflow retains the
existing reset policy rather than blocking PTY input.

## Client boundary

```text
runtime_messages.handleServerMessage(.graphics_*)
  -> pane_graphics.applyPaneGraphics
     -> pane_graphics.applyResources -> graphics.apply (GraphicsRetention)
     -> changed: pane_graphics.setFallback
     -> revision break: request_graphics_snapshot
     -> shared-map failure: configure_graphics(shared=false), then snapshot
  -> adapter observes model and graphics ingress revisions

committed host capability (images support changed)
  -> pane_graphics.syncFallbacks + model.to_host.invalidate_placements
  -> bounded pane traversal -> pane_graphics.setFallback
```

`pane_graphics.applyPaneGraphics` translates physical ingress results into semantic fallback
or runtime recovery directly. The resource store owns allocations, shared
mappings, quotas and image identities. Accepted ingress advances its physical
revision; stale deltas and rejected operations do not. The window observes this
revision independently of the model, including when a change causes no
fallback change.

The window binds `graphics_delivery.Store` (`src/gui/graphics_delivery.zig`)
as its retained store; `GuiAdapter.applyGraphics` applies each command to it.
The store has no GPU image consumer yet, and the window reports images as
unsupported to the shared client, so a pane that holds graphics carries the
fallback flag. The window bootstraps with shared graphics off. The headless
client accepts graphics commands and drops them.

Only `pane_graphics.setFallback` commits cell fallback. A changed value
advances the pane-graphics revision; unknown panes and repeats do nothing.
`syncFallbacks` uses the committed host capability. Supported hosts clear
fallback without querying physical presence; other capability states query
once per pane. The traversal walks `model.panes`, bounded by fixed
workspace/pane capacity.

A graphics revision break requests a canonical snapshot without changing
fallback. Snapshot begin clears the physical replica; resource/placement
messages rebuild it at one revision, and end removes incomplete resources.
A failed shared mapping first disables shared transfer and then requests the
snapshot, so the runtime can resend bounded pixel chunks. Failure of the later
enqueue preserves the already requested downgrade.

## Budget and bounds

Resource ingestion belongs to the media path. Images, chunks and placements
are bounded by the graphics schema and the resource store's per-pane and
global quotas (`GenericResourceStore`). Repeated frames replace obsolete
generations in the store rather than forming an unbounded replay queue.

Fallback synchronization allocates nothing and visits at most 64 tabs with 64
panes each. A supported host performs no store queries. Every other capability
state performs at most 4096 bounded presence lookups and transition attempts;
repeated semantic values preserve `pane_graphics_revision`.

The socket dispatcher is still the decoded message entrypoint. This slice
separates ownership and scheduling policy; moving bulk ingestion behind a
dedicated media queue is a separate scheduling change.

## Verification

Source: `src/client/panes/pane_graphics.zig` and the `graphics:
GraphicsRetention` store each adapter binds on `Client`.
`src/client_tests/graphics_and_clipboard.zig` checks recovery IPC,
physical-only presentation observation and downgrade-before-resync ordering.
Resource-store and model tests cover quotas, stale revisions, fallback ownership
and no-op semantics. Runtime PNG tests and `src/transport_integration_test.zig`
cover fragmented PNG ingestion, RGBA delivery and snapshot reconstruction.
