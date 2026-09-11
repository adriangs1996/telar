const pane_input = @import("pane_input.zig");
const root = @import("../../input/input_namespace.zig");
const Prepared = @This();

source: pane_input.Source,
bytes: []const u8,
restore_viewport: bool = true,
limit: usize = root.max_encoded_bytes,
empty_is_noop: bool = false,
