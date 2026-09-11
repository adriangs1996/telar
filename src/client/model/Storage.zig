const history_palette = @import("history_palette.zig");
const max_history_output_bytes_module = @import("telar-core").max_history_output_bytes;
const max_history_command_bytes_module = @import("telar-core").max_history_command_bytes;
const Storage = @This();

commands: [history_palette.max_command_storage]u8 = undefined,
output: [max_history_output_bytes_module]u8 = undefined,
selected_command: [max_history_command_bytes_module]u8 = undefined,
