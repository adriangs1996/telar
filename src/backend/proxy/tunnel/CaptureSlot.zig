const HalfType = @import("../capture/Half.zig");
const CaptureSlot = @This();

stream_id: u32,
half: *HalfType,
