const Work = @This();
const source_namespace = @import("media.zig");
const core = @import("telar-core");
pane: *source_namespace.Pane,
current_size: core.schema.TerminalSize,
