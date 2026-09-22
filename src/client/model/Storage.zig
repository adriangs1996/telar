const core = @import("telar-core");
const history_palette = @import("history_palette.zig");
const Storage = @This();

commands: [history_palette.max_command_storage]u8 = undefined,
output: [core.max_history_output_bytes]u8 = undefined,
selected_command: [core.max_history_command_bytes]u8 = undefined,
