//! Incremental copy-mode search. Each runtime turn inspects at most 32 rows.

pub const max_rows = 10_000;
pub const max_cols = 512;
