//! Incremental copy-mode search. Each runtime turn inspects at most 32 rows.
const std = @import("std");
const core = @import("telar-core");
pub const schema = core.schema;
pub const max_rows = 10_000;
pub const max_cols = 512;

pub const Cursor = @import("Cursor.zig");
