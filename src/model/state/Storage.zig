const core = @import("telar-core");
const history_palette = @import("history_palette.zig");

// SAFETY: HistoryPaletteState copies complete commands before publishing their entry ranges; commandAt reads only those ranges.
commands: [history_palette.max_command_storage]u8 = undefined,
// SAFETY: HistoryPaletteState.applyOutput initializes this through plainText before setting output_len; outputSlice reads only that prefix.
output: [core.max_history_output_bytes]u8 = undefined,
// SAFETY: HistoryPaletteState copies the selected command before setting full_len; commandAt reads it only for the matching selection.
selected_command: [core.max_history_command_bytes]u8 = undefined,
