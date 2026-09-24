const keyinput = @import("keyinput");
const std = @import("std");

bytes: []const u8,
phase: keyinput.Key.Phase = .press,
physical: ?keyinput.Key.Physical = null,
target_id: u64 = 0,
generation: u64 = 0,
replacement_start: u32 = std.math.maxInt(u32),
replacement_end: u32 = std.math.maxInt(u32),
