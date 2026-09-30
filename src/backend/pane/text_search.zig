//! Incremental copy-mode search over a pane's scrollback, bounded by the
//! protocol's needle and match limits. Each runtime turn inspects at most
//! `rows_per_turn` rows, newest first.
const core = @import("telar-core");
const std = @import("std");
const vtgrid = @import("vtgrid");

/// Newest scrollback rows one search reaches. Ghostty keeps 8 bytes a cell
/// and a row header, so a pane's 10 MB of scrollback is about 15,000 rows at
/// 80 columns; this reaches the whole of it down to 25 columns.
pub const max_rows = 50_000;
pub const max_cols = 512;
pub const rows_per_turn = 32;
/// Wall time one turn may take on average, the pause a busy pane's turn
/// waits for included.
const turn_budget_ns = std.time.ns_per_ms;
/// Turns a search of every row takes.
const turns = std.math.divCeil(u64, max_rows, rows_per_turn) catch unreachable;
/// A search that has not finished by then answers with what it found.
pub const deadline_ns: u64 = turns * turn_budget_ns;

pub const rows_limit = core.Limit.declare("pane_search.max_rows", "rows", max_rows);
pub const columns_limit = core.Limit.declare("pane_search.max_cols", "cells in one row", max_cols);
pub const matches_limit = core.Limit.declare("pane_search.max_search_matches", "matches", core.max_search_matches);
pub const deadline_limit = core.Limit.declare("pane_search.deadline_ms", "ms", deadline_ns / std.time.ns_per_ms);

pub const Search = vtgrid.GenericSearch(core.SearchMatch, .{
    .needle_codepoints = core.max_search_needle_bytes,
    .matches = core.max_search_matches,
    .rows = max_rows,
    .columns = max_cols,
    .rows_per_turn = rows_per_turn,
});
