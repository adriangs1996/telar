const id = @import("../id.zig");
const PathMatch = @import("../PathMatch.zig");
/// Reply to `find_paths`: the best matches in rank order. `scanned` counts
/// the paths indexed so far; `complete` is false while the index still
/// grows, and `truncated` reports that it stopped at its bound.
const PathResults = @This();

request_id: id.RequestId,
root: []const u8,
scanned: u32 = 0,
complete: bool = true,
truncated: bool = false,
matches: []const PathMatch = &.{},
