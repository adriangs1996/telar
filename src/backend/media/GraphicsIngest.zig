const std = @import("std");
const GraphicsIngest = @This();

io: std.Io,
previous_loading_id: ?u32,
completed_commands: usize,
