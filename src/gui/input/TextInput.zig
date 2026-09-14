const Key = @import("telar-client").Key;

bytes: []const u8,
phase: Key.Phase = .press,
physical: ?Key.Physical = null,
target_id: u64 = 0,
generation: u64 = 0,
replacement_start: u32 = @import("std").math.maxInt(u32),
replacement_end: u32 = @import("std").math.maxInt(u32),
