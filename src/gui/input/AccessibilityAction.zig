target_id: u64,
generation: u64,
revision: u64 = 0,
action: Action,
text: []const u8 = "",
selection_start: u32 = 0,
selection_end: u32 = 0,
replacement_start: u32 = @import("std").math.maxInt(u32),
replacement_end: u32 = @import("std").math.maxInt(u32),

pub const Action = enum(u32) { press = 1, focus = 2, set_value = 4, set_selection = 8, increment = 16, decrement = 32, copy = 64, cut = 128, paste = 256, replace_range = 512 };
