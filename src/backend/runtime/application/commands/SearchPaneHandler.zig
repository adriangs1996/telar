const AttachmentStoreType = @import("../../attachment/AttachmentStore.zig");
const SearchPane = @import("SearchPane.zig");
const search_pane = @import("search_pane.zig");
const Matches = @import("Matches.zig");
const SearchPaneHandler = @This();

attachments: *AttachmentStoreType,

/// Resolves attachment authority and runs the bounded search.
///
/// ```zig
/// const result = handler.execute(.{ .pane_id = pane_id, .needle = "error" });
/// ```
pub fn execute(handler: *SearchPaneHandler, command: SearchPane) search_pane.SearchPaneResult {
    const attachment = handler.attachments.find(command.pane_id) orelse return .pane_not_attached;
    var matches: Matches = .{};
    const result = attachment.pane.searchText(command.needle, &matches.items);
    matches.count = result.count;
    matches.truncated = result.truncated;
    return .{ .found = matches };
}
