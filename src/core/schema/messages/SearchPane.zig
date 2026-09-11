const id = @import("../id.zig");
/// Copy-mode text search over one attached pane's retained history.
const SearchPane = @This();

request_id: id.RequestId,
pane_id: id.PaneId,
needle: []const u8,
