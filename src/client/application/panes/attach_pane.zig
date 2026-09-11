//! Application use cases for confirming and recovering one pane attachment.

const AttachPaneTestingModel = @import("AttachPaneTestingModel.zig");
const ConfirmPaneAttachmentHandler = @import("ConfirmPaneAttachmentHandler.zig");
const std = @import("std");
const types = @import("../../model/types.zig");
const VersionType = @import("../../model/Version.zig");
const AttachPaneRecoveryCapture = @import("AttachPaneRecoveryCapture.zig");
const RecoverPaneAttachmentHandler = @import("RecoverPaneAttachmentHandler.zig");

test "ConfirmPaneAttachmentHandler validates and commits one exact confirmation" {
    var testing = try AttachPaneTestingModel.init();
    defer testing.deinit();
    var handler: ConfirmPaneAttachmentHandler = .{ .model = testing.model };
    const attachment = testing.attachment();

    var mismatch = attachment;
    mismatch.pane_id = @enumFromInt(9);
    try std.testing.expectError(error.UnexpectedPane, handler.execute(.{
        .requested = attachment,
        .confirmed = mismatch,
        .created = false,
    }));
    try std.testing.expectError(error.UnexpectedPane, handler.execute(.{
        .requested = attachment,
        .confirmed = attachment,
        .created = true,
    }));
    try std.testing.expect(!testing.model.workspace.findPane(testing.discovered).?.attached);

    try std.testing.expectEqual(types.PaneAttachmentConfirmation.confirmed, try handler.execute(.{
        .requested = attachment,
        .confirmed = attachment,
        .created = false,
    }));
    try std.testing.expect(testing.model.workspace.findPane(testing.discovered).?.attached);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "ConfirmPaneAttachmentHandler ignores a confirmation made stale by tab state" {
    var testing = try AttachPaneTestingModel.init();
    defer testing.deinit();
    _ = testing.model.workspace.active().?.model.removePane(testing.discovered);
    var handler: ConfirmPaneAttachmentHandler = .{ .model = testing.model };
    const attachment = testing.attachment();

    try std.testing.expectEqual(types.PaneAttachmentConfirmation.stale, try handler.execute(.{
        .requested = attachment,
        .confirmed = attachment,
        .created = false,
    }));
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "RecoverPaneAttachmentHandler refreshes only an attachment still needed" {
    var testing = try AttachPaneTestingModel.init();
    defer testing.deinit();
    var capture: AttachPaneRecoveryCapture = .{};
    var handler: RecoverPaneAttachmentHandler = .{
        .model = testing.model,
        .snapshots = capture.handler(),
    };
    const attachment = testing.attachment();

    try std.testing.expect(try handler.execute(attachment));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(testing.location, capture.location.?);

    _ = try testing.model.confirmPaneAttachment(attachment);
    try std.testing.expect(!try handler.execute(attachment));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "RecoverPaneAttachmentHandler propagates refresh failure without model mutation" {
    var testing = try AttachPaneTestingModel.init();
    defer testing.deinit();
    var capture: AttachPaneRecoveryCapture = .{ .fail = true };
    var handler: RecoverPaneAttachmentHandler = .{
        .model = testing.model,
        .snapshots = capture.handler(),
    };

    try std.testing.expectError(error.RefreshFailed, handler.execute(testing.attachment()));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(!testing.model.workspace.findPane(testing.discovered).?.attached);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}
