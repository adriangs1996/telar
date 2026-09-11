const Command = @This();
const source_namespace = @import("view_interaction.zig");
intent: source_namespace.Intent = .none,
layout_changed: bool = false,
consumed: bool = false,
