//! Application policy for requesting one runtime attachment per detached pane
//! that has visible content.

const RectType = @import("telar-core").Rect;
const PaneAttachmentRequestsTestingModel = @import("PaneAttachmentRequestsTestingModel.zig");
const PaneAttachmentRequestsCapture = @import("PaneAttachmentRequestsCapture.zig");
const RequestActivePaneAttachmentsHandler = @import("RequestActivePaneAttachmentsHandler.zig");
const std = @import("std");

const wide: RectType = .{ .w = 40, .h = 10 };
const cramped: RectType = .{ .w = 4, .h = 3 };

test "RequestPaneAttachmentsHandler requests only detached panes with content" {
    var testing = try PaneAttachmentRequestsTestingModel.init();
    defer testing.deinit();
    try testing.reconcile(wide);
    var capture: PaneAttachmentRequestsCapture = .{};
    var use_case: RequestActivePaneAttachmentsHandler = .{ .model = testing.model, .effects = capture.effects() };

    try std.testing.expectEqual(@as(usize, 1), try use_case.execute(wide));

    try std.testing.expectEqual(testing.discovered, capture.requests[0].pane_id);
    try std.testing.expectEqual(testing.location, capture.requests[0].location);
    try std.testing.expectEqual(@as(u16, 18), capture.requests[0].size.cols);
}

test "RequestPaneAttachmentsHandler skips a pending request and an empty pane" {
    var testing = try PaneAttachmentRequestsTestingModel.init();
    defer testing.deinit();
    try testing.reconcile(cramped);
    var capture: PaneAttachmentRequestsCapture = .{};
    var use_case: RequestActivePaneAttachmentsHandler = .{ .model = testing.model, .effects = capture.effects() };

    try std.testing.expectEqual(@as(usize, 0), try use_case.execute(cramped));

    capture.pending = testing.discovered;
    try std.testing.expectEqual(@as(usize, 0), try use_case.execute(wide));
    capture.pending = null;
    try std.testing.expectEqual(@as(usize, 1), try use_case.execute(wide));
    try std.testing.expectEqual(testing.discovered, capture.requests[0].pane_id);
}

test "RequestActivePaneAttachmentsHandler waits for the canonical snapshot" {
    var testing = try PaneAttachmentRequestsTestingModel.init();
    defer testing.deinit();
    var capture: PaneAttachmentRequestsCapture = .{};
    var use_case: RequestActivePaneAttachmentsHandler = .{ .model = testing.model, .effects = capture.effects() };

    try std.testing.expectEqual(@as(usize, 0), try use_case.execute(wide));
    try std.testing.expectEqual(@as(usize, 0), capture.request_count);
}
