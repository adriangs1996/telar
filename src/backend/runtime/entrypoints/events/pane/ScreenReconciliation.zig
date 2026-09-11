const ScreenReconciliation = @This();
const source_namespace = @import("observation.zig");
const history = @import("../../../../history/root.zig");
pane: *source_namespace.Pane,
stats: history.observer.Stats,
shell_foreground: bool,
