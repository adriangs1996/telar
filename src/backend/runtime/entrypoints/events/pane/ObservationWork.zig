const Work = @This();
const source_namespace = @import("observation.zig");
const agent_process = @import("../../../../process/root.zig");
pane: *source_namespace.Pane,
current_size: source_namespace.schema.TerminalSize,
process_cache: agent_process.Cache,
