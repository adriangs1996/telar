//! One built-in action the command palette can list and run.
const action_module = @import("../input/action.zig");

action: action_module.Action,
/// Searchable label shown in the `>` list; static and control-free.
label: []const u8,
