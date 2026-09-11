const ImageIdentityType = @import("telar-client").ImageIdentity;
const max_placements_per_pane_module = @import("telar-core").max_placements_per_pane;
const FallbackPlacement = @import("FallbackPlacement.zig");
/// A chunked transfer the frame budget interrupted. The next frame resumes
/// it before emitting any other graphics escape, which the protocol demands.
const PartialTransmission = @This();

key: ImageIdentityType,
external_id: u32,
offset: usize,
/// The open transfer streams the entry's compressed bytes, so a resume
/// must keep reading the same buffer the header's `o=z` promised.
compressed: bool = false,
fallback_count: usize = 0,
fallbacks: [max_placements_per_pane_module]FallbackPlacement = undefined,
