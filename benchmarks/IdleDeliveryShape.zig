//! How many clients attach how many panes in an idle delivery benchmark.
const core = @import("telar-core");

clients: usize,
panes: usize,
size: core.TerminalSize,
