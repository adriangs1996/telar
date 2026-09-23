const view_interaction = @import("view_interaction.zig");
const Command = @This();

intent: view_interaction.Intent = .none,
layout_changed: bool = false,
consumed: bool = false,
