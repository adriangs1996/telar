//! Application policy for requesting one runtime attachment per detached pane
//! that has visible content.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../workspace/root.zig");
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;
pub const tabs_mod = workspace_capability.tabs;
pub const ui = core.ui;

pub const PaneAttachmentRequest = @import("PaneAttachmentRequest.zig");

pub const Effects = @import("PaneAttachmentRequestsEffects.zig");

pub const RequestPaneAttachmentsHandler = @import("RequestPaneAttachmentsHandler.zig");

pub const RequestActivePaneAttachmentsHandler = @import("RequestActivePaneAttachmentsHandler.zig");

const TestingModel = @import("PaneAttachmentRequestsTestingModel.zig");

const Capture = @import("PaneAttachmentRequestsCapture.zig");

const wide: ui.Rect = .{ .w = 40, .h = 10 };
const cramped: ui.Rect = .{ .w = 4, .h = 3 };

test "RequestPaneAttachmentsHandler requests only detached panes with content" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    try testing.reconcile(wide);
    var capture: Capture = .{};
    var use_case: RequestActivePaneAttachmentsHandler = .{ .model = testing.model, .effects = capture.effects() };

    try std.testing.expectEqual(@as(usize, 1), try use_case.execute(wide));

    try std.testing.expectEqual(testing.discovered, capture.requests[0].pane_id);
    try std.testing.expectEqual(testing.location, capture.requests[0].location);
    try std.testing.expectEqual(@as(u16, 18), capture.requests[0].size.cols);
}

test "RequestPaneAttachmentsHandler skips a pending request and an empty pane" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    try testing.reconcile(cramped);
    var capture: Capture = .{};
    var use_case: RequestActivePaneAttachmentsHandler = .{ .model = testing.model, .effects = capture.effects() };

    try std.testing.expectEqual(@as(usize, 0), try use_case.execute(cramped));

    capture.pending = testing.discovered;
    try std.testing.expectEqual(@as(usize, 0), try use_case.execute(wide));
    capture.pending = null;
    try std.testing.expectEqual(@as(usize, 1), try use_case.execute(wide));
    try std.testing.expectEqual(testing.discovered, capture.requests[0].pane_id);
}

test "RequestActivePaneAttachmentsHandler waits for the canonical snapshot" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{};
    var use_case: RequestActivePaneAttachmentsHandler = .{ .model = testing.model, .effects = capture.effects() };

    try std.testing.expectEqual(@as(usize, 0), try use_case.execute(wide));
    try std.testing.expectEqual(@as(usize, 0), capture.request_count);
}
