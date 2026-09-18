const Cursor = @import("../../AgentHistoryCursor.zig");
const Page = @import("../../AgentHistoryPage.zig");

request_id: @import("../id.zig").RequestId,
view_generation: u64,
snapshot: @import("AgentThreadSnapshotView.zig"),
before: []const u8,
after: []const u8,
has_before: bool,
has_after: bool,

/// Copies validated wire data into an owned reading page.
/// Example: `try response.copyTo(page);`
pub fn copyTo(view: @This(), page: *Page) !void {
    page.request_id = view.request_id;
    page.view_generation = view.view_generation;
    page.before = try Cursor.init(view.before);
    page.after = try Cursor.init(view.after);
    page.has_before = view.has_before;
    page.has_after = view.has_after;
    try view.snapshot.copyTo(&page.snapshot);
}
