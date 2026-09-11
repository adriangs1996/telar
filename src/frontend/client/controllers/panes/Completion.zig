const Completion = @This();
const source_namespace = @import("pane_focus_commands.zig");
outcome: source_namespace.schema.PaneFocusOutcome,
focused_pane_id: source_namespace.schema.PaneId,
