const std = @import("std");
const data = @import("model");

bytes: []const u8,
phase: data.Key.Phase = .press,
physical: ?data.Key.Physical = null,
target_id: u64 = 0,
generation: u64 = 0,
replacement_start: u32 = std.math.maxInt(u32),
replacement_end: u32 = std.math.maxInt(u32),
