//! Application policy for retiring every tab attachment in the current
//! client workspace before a handoff.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;
const pane_focus_reporting = @import("../panes/root.zig").pane_focus_reporting;
const pane_paste = @import("../input/root.zig").pane_paste;
const tab_attachment_retirement = @import("../tabs/root.zig").tab_attachment_retirement;

pub const schema = core.schema;

pub const RetireWorkspaceAttachmentsHandler = @import("RetireWorkspaceAttachmentsHandler.zig");

pub const Event = union(enum) {
    attachment_pending: schema.PaneId,
    paste_finish: schema.PaneId,
    focus_out: schema.PaneId,
    detach: schema.PaneId,
    retire_attachment: schema.PaneId,
    hide_graphics: schema.PaneId,
};

const TestingModel = @import("WorkspaceAttachmentRetirementTestingModel.zig");

const Capture = @import("WorkspaceAttachmentRetirementCapture.zig");

test "RetireWorkspaceAttachmentsHandler retires every tab in stable order" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .pending_pane = testing.sibling,
    };
    var handler = capture.handler();

    try handler.execute();

    try std.testing.expectEqualDeep(&[_]Event{
        .{ .paste_finish = testing.root },
        .{ .focus_out = testing.root },
        .{ .attachment_pending = testing.root },
        .{ .detach = testing.root },
        .{ .retire_attachment = testing.root },
        .{ .hide_graphics = testing.root },
        .{ .attachment_pending = testing.sibling },
        .{ .detach = testing.sibling },
        .{ .retire_attachment = testing.sibling },
        .{ .hide_graphics = testing.sibling },
        .{ .attachment_pending = testing.other_root },
        .{ .detach = testing.other_root },
        .{ .retire_attachment = testing.other_root },
        .{ .hide_graphics = testing.other_root },
    }, capture.eventSlice());
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
    try std.testing.expect(!testing.model.workspace.findPane(testing.root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.sibling).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.other_root).?.attached);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "RetireWorkspaceAttachmentsHandler preserves completed tabs on failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{
        .model = testing.model,
        .pending_pane = testing.sibling,
        .fail_detach = testing.other_root,
    };
    var handler = capture.handler();

    try std.testing.expectError(error.DetachFailed, handler.execute());

    try std.testing.expectEqualDeep(Event{ .detach = testing.other_root }, capture.eventSlice()[capture.event_count - 1]);
    try std.testing.expect(!testing.model.panePasteActive());
    try std.testing.expect(testing.model.reportedPaneFocus() == null);
    try std.testing.expect(!testing.model.workspace.findPane(testing.root).?.attached);
    try std.testing.expect(!testing.model.workspace.findPane(testing.sibling).?.attached);
    try std.testing.expect(testing.model.workspace.findPane(testing.other_root).?.attached);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "RetireWorkspaceAttachmentsHandler accepts an empty projection" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: Capture = .{
        .model = &model,
        .pending_pane = null,
    };
    var handler = capture.handler();

    try handler.execute();

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqualDeep(client_model.Version{}, model.version());
}
