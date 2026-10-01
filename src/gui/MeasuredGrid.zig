//! The complete cells a viewport holds, and how many it would hold if the
//! grid had no bound.
const core = @import("telar-core");

size: core.TerminalSize,
/// Cells the viewport holds when `size` was cut to `core.max_cell_count`.
cut_from: ?u64 = null,
