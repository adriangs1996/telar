const Half = @import("../capture/Half.zig");
const CaptureSlot = @This();

stream_id: u32,
half: *Half,
