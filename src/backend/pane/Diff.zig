const Diff = @This();

span_count: usize = 0,
damaged_rows: usize = 0,
scanned_cells: usize = 0,
coalesced_spans: usize = 0,
bridged_cells: usize = 0,
bytes_saved: usize = 0,
snapshot_required: bool = false,
