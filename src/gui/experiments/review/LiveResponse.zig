const LiveRevision = @import("LiveRevision.zig");
const ReviewFeedback = @import("ReviewFeedback.zig");

schema: u32,
session_id: []const u8,
revisions: []const LiveRevision,
comments: []const ReviewFeedback = &.{},
status: enum { reviewable, working, complete, @"error" },
@"error": ?[]const u8 = null,
