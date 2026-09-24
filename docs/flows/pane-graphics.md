# Pane graphics

Pane graphics carry image resources and placements from the runtime's terminal
emulator to the host terminal. The runtime owns the canonical image identity,
generation, pixels and placement facts. The disposable client owns mapped
resources, host identifiers, clipping, visibility, transmission and the cell
fallback used when Kitty graphics are unavailable.

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
mappings, quotas, image identities and transmission damage. Accepted ingress
advances its physical revision; stale deltas and rejected operations do not.
The presenter observes this revision independently of the model, including when
supported graphics cause no fallback change.

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

## Host replies

The shared transmission asks the host for a reply. `host_inputs.terminalResponse`
hands every Kitty reply first to `host_capabilities.observe`, which consumes
the probe identities, then to `kitty_delivery.noteHostReply` on the TUI's
`graphics_store` for exterior pane image ids: `OK` marks the object consumed,
an error reclaims the name and retransmits inline, and either bumps the
graphics ingress so the next paced frame retires or resends. Unknown ids
change nothing.

## Budget and bounds

Resource ingestion belongs to the media path. Images, chunks and placements
are bounded by the graphics schema and `kitty.Store` quotas. The presenter
composes and writes cells first. Pane graphics control escapes (shared names,
placements, deletes) are a few hundred bytes per image, so the cell frame
carries them inside its own synchronized update, after the cells and before
the cursor; a graphics-only ingress therefore reaches the host at the pacer
cadence with no extra tick. Pixel streams and UI rasters belong to the
separate bulk media tick, which emits at most the configured KGP byte budget
and yields while interactive cell work is pending; a tick that yields runs at
that frame's completion rather than a pacer interval later. An open chunked
transfer owns the graphics stream, so the cell frame carries no control
escapes until the bulk pass closes it. Repeated frames replace obsolete
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
`src/frontend/client/tests/graphics_and_clipboard.zig` checks recovery IPC,
physical-only presentation observation and downgrade-before-resync ordering.
Resource-store and model tests cover quotas, stale revisions, fallback ownership
and no-op semantics. Runtime PNG tests and `src/transport_integration_test.zig`
cover fragmented PNG ingestion, RGBA delivery and snapshot reconstruction.
