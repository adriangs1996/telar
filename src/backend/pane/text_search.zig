//! Incremental copy-mode search over a pane's scrollback, bounded by the
//! protocol's needle and match limits. Each runtime turn inspects at most
//! 32 rows.
const core = @import("telar-core");
const vtgrid = @import("vtgrid");

const max_rows = 10_000;
const max_cols = 512;
const rows_per_turn = 32;

pub const Search = vtgrid.GenericSearch(core.SearchMatch, .{
    .needle_codepoints = core.max_search_needle_bytes,
    .matches = core.max_search_matches,
    .rows = max_rows,
    .columns = max_cols,
    .rows_per_turn = rows_per_turn,
});
