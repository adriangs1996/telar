const TimingType = @import("telar-core").Timing;
const GraphicsCounts = @This();

images: u32,
placements: u32,
/// Freezes refused because the next image exceeded the client's or
/// the runtime's memory credit.
stage_blocked: u32,
/// Transfers adopted from objects the media actor froze.
adopted: u32,
/// Time spent copying frozen generations out of live media storage
/// on the runtime thread, the fallback when nothing was adopted.
freeze: TimingType,
