const view_interaction = @import("view_interaction.zig");

intent: view_interaction.Intent = .none,
layout_changed: bool = false,
consumed: bool = false,
