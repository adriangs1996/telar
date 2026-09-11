//! Application policy for retiring every tab attachment in the current
//! client workspace before a handoff.

const PaneIdType = @import("telar-core").PaneId;
const WorkspaceAttachmentRetirementTestingModel = @import("WorkspaceAttachmentRetirementTestingModel.zig");
const WorkspaceAttachmentRetirementCapture = @import("WorkspaceAttachmentRetirementCapture.zig");
const std = @import("std");
const VersionType = @import("../../model/Version.zig");
const ModelType = @import("../../model/Model.zig");

pub const Event = union(enum) {
    attachment_pending: PaneIdType,
    paste_finish: PaneIdType,
    focus_out: PaneIdType,
    detach: PaneIdType,
    retire_attachment: PaneIdType,
    hide_graphics: PaneIdType,
};

test "RetireWorkspaceAttachmentsHandler retires every tab in stable order" {
    var testing = try WorkspaceAttachmentRetirementTestingModel.init();
    defer testing.deinit();
    var capture: WorkspaceAttachmentRetirementCapture = .{
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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "RetireWorkspaceAttachmentsHandler preserves completed tabs on failure" {
    var testing = try WorkspaceAttachmentRetirementTestingModel.init();
    defer testing.deinit();
    var capture: WorkspaceAttachmentRetirementCapture = .{
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
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "RetireWorkspaceAttachmentsHandler accepts an empty projection" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: WorkspaceAttachmentRetirementCapture = .{
        .model = &model,
        .pending_pane = null,
    };
    var handler = capture.handler();

    try handler.execute();

    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
    try std.testing.expectEqualDeep(VersionType{}, model.version());
}
