const client = @import("telar-client");
const core = @import("telar-core");
const FallbackPlacement = @import("FallbackPlacement.zig");
/// A chunked transfer the frame budget interrupted. The next frame resumes
/// it before emitting any other graphics escape, which the protocol demands.
const PartialTransmission = @This();

key: client.ImageIdentity,
external_id: u32,
offset: usize,
/// The open transfer streams the entry's compressed bytes, so a resume
/// must keep reading the same buffer the header's `o=z` promised.
compressed: bool = false,
fallback_count: usize = 0,
fallbacks: [core.max_placements_per_pane]FallbackPlacement = undefined,
