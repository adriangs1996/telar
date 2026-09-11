const HostResizeCommit = @This();
const source_namespace = @import("types.zig");
previous: source_namespace.schema.TerminalSize,
current: source_namespace.schema.TerminalSize,
grid_changed: bool,
cell_size_changed: bool,
host_revision: u64,
