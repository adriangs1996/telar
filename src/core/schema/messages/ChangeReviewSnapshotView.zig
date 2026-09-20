const id = @import("../id.zig");
const review = @import("../../change_review.zig");
const Comment = @import("../../ChangeReviewComment.zig");
request_id: id.RequestId,
pane_id: id.PaneId,
pane_generation: u64,
session: []const u8 = "",
revision: u64 = 0,
edition_id: u64 = 0,
latest_edition_id: u64 = 0,
previous_edition_id: u64 = 0,
next_edition_id: u64 = 0,
source: review.Source = .provider_patch,
patch: []const u8 = "",
comment_storage: [review.max_comments]Comment = @splat(.{}),
comment_count: u8 = 0,
reviewed: bool = false,
delivery: review.Delivery = .idle,
feedback_id: u64 = 0,
feedback: []const u8 = "",
status: []const u8 = "",

/// Borrows validated comments from the containing wire frame.
/// Example: `for (snapshot.comments()) |comment| draw(comment);`.
pub fn comments(self: *const @This()) []const Comment {
    return self.comment_storage[0..self.comment_count];
}
