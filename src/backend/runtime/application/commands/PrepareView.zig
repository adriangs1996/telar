const PrepareView = @This();
const pane_mod = @import("../../../pane/root.zig");
const source_namespace = @import("open_pane.zig");
pane: pane_mod.PaneLaunched,
size: source_namespace.schema.TerminalSize,
