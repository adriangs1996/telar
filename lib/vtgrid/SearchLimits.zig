//! A search's compile-time bounds.
const SearchLimits = @This();

/// Codepoints of the needle kept; the rest is ignored.
needle_codepoints: usize,
/// Matches reported before the search stops as truncated.
matches: usize,
/// Newest scrollback rows searched.
rows: usize,
/// Columns of one row searched.
columns: usize,
/// Rows one `advance` inspects.
rows_per_turn: usize,
