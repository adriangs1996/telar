//! One built-in action the command palette can list and run.
const Action = @import("../input/action.zig").Action;

action: Action,
/// Searchable label shown in the `>` list; static and control-free.
label: []const u8,
