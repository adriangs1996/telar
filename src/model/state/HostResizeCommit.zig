const core = @import("telar-core");
const HostResizeCommit = @This();

previous: core.TerminalSize,
current: core.TerminalSize,
grid_changed: bool,
cell_size_changed: bool,
host_revision: u64,
