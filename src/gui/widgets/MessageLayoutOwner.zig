//! Provenance identifies one immutable snapshot slice independently of its hash.
const core = @import("telar-core");
pane_id: core.PaneId,
attachment_generation: u64,
pane_generation: u64,
snapshot_revision: u64,
item_identity: u64,
section: enum { body, metadata, approval },
source_offset: u32,
