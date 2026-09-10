# Graphics retention and host effects

`client.graphics.ResourceStore(Delivery)` owns image ingestion, revisions,
metadata, raw/shared pixel allocations, quotas and credits. The delivery policy
owns its resource extensions. Kitty IDs, partial transmissions, compression
jobs, consume deadlines and emitted placements remain in
`frontend/graphics/kitty_delivery.zig`; output encoding remains in the TUI.
There is no second ingestion implementation or second VT.

`client.attachments.Catalog(Delivery)` owns attachment identities, targets,
markers, modal selection and bounded sensitive PNG storage. Kitty thumbnails,
placements and transmission live in `frontend/attachments/delivery.zig`.
Clipboard capture remains a host worker. Clipboard writes now use a shared
handler's narrow port; links, notifications, sound and appearance use the
existing application effect ports extracted in phase 3.

Both catalogs have terminal-free retained-byte consumers. They test ownership
across asynchronous presentation, not a fake Kitty store or terminal surface.

## Lifetime and failure rules

- Delivery callbacks are synchronous. Borrowed entry data must not escape them.
- An image lease pins completed pixels, not a hash-map entry. Replacement of the
  same identity while leased requests resynchronization rather than freeing it.
- Snapshot retirement and pane removal retain allocations still in use. Retired
  allocations remain charged against the byte quota until actual release.
- A detached allocation carries its own no-credit flag. Reattachment cannot
  redirect an old release into the new attachment's credit account.
- Rejected shared transfers relinquish their unique name, including rejection
  before mapping. The runtime's shared-transfer contract assigns unlinking to
  the consumer or discarder of the name.
- Attachment eviction skips leased slots. Dismissal removes semantic visibility;
  secure wiping remains in the media reap after the last lease returns.
- Drivers must cancel/join their work and return leases before catalog teardown.
  The TUI retains its existing copied-input compression worker protocol.

Tests cover these rules, allocation-failure cleanup, and the existing Kitty
transfer, compression, fallback and clipping regressions. ReleaseSafe and Debug
shared tests, frontend tests, semantic analysis, the diagnostics-enabled
ReleaseFast build and shared-client codestyle pass. Logs are retained here.

This is not a visual/FPS or performance acceptance claim. End-to-end graphics
and paired performance gates remain part of phase 6.
