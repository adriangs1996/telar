const TerminalSizeType = @import("telar-core").TerminalSize;
const HostResizeCommit = @This();

previous: TerminalSizeType,
current: TerminalSizeType,
grid_changed: bool,
cell_size_changed: bool,
host_revision: u64,
