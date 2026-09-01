//! Application use cases for confirming and recovering one pane attachment.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../model.zig");
const tab_snapshot_recovery = @import("tab_snapshot_recovery.zig");

const schema = core.schema;

pub const PaneAttachment = client_model.PaneAttachment;

pub const ConfirmPaneAttachment = struct {
    requested: PaneAttachment,
    confirmed: PaneAttachment,
    created: bool,
};

pub const ConfirmPaneAttachmentHandler = struct {
    model: *client_model.Model,

    /// Validates the runtime confirmation before committing client attachment
    /// state. Confirmations made stale by a tab change are harmless no-ops.
    ///
    /// ```zig
    /// const result = try handler.execute(command);
    /// ```
    pub fn execute(handler: *ConfirmPaneAttachmentHandler, command: ConfirmPaneAttachment) !client_model.PaneAttachmentConfirmation {
        if (command.created or !std.meta.eql(command.requested, command.confirmed)) {
            return error.UnexpectedPane;
        }

        return handler.model.confirmPaneAttachment(command.confirmed);
    }
};

pub const RecoverPaneAttachmentHandler = struct {
    model: *const client_model.Model,
    snapshots: tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler,

    /// Requests canonical membership only while the failed attachment still
    /// belongs to the active tab and remains detached.
    ///
    /// ```zig
    /// _ = try handler.execute(attachment);
    /// ```
    pub fn execute(handler: *RecoverPaneAttachmentHandler, attachment: PaneAttachment) !bool {
        if (!handler.model.needsPaneAttachment(attachment)) {
            return false;
        }

        _ = try handler.snapshots.execute(attachment.location);
        return true;
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    location: schema.TabLocation,
    discovered: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        const discovered: schema.PaneId = @enumFromInt(2);
        try model.workspace.bootstrap(@enumFromInt(1), location, .{ .cols = 20, .rows = 5 });
        try model.workspace.active().?.model.addDiscovered(discovered, location, .{ .w = 40, .h = 10 });

        return .{ .model = model, .location = location, .discovered = discovered };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }

    fn attachment(testing: *const TestingModel) PaneAttachment {
        return .{ .pane_id = testing.discovered, .location = testing.location };
    }
};

const RecoveryCapture = struct {
    calls: usize = 0,
    location: ?schema.TabLocation = null,
    fail: bool = false,

    fn handler(capture: *RecoveryCapture) tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler {
        return .{ .effects = .{
            .context = capture,
            .pending = pending,
            .request = refresh,
        } };
    }

    fn pending(_: *anyopaque) bool {
        return false;
    }

    fn refresh(context: *anyopaque, location: schema.TabLocation) !void {
        const capture: *RecoveryCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.location = location;

        if (capture.fail) {
            return error.RefreshFailed;
        }
    }
};

test "ConfirmPaneAttachmentHandler validates and commits one exact confirmation" {
    var testing = try TestingModel.init();
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

    try std.testing.expectEqual(client_model.PaneAttachmentConfirmation.confirmed, try handler.execute(.{
        .requested = attachment,
        .confirmed = attachment,
        .created = false,
    }));
    try std.testing.expect(testing.model.workspace.findPane(testing.discovered).?.attached);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "ConfirmPaneAttachmentHandler ignores a confirmation made stale by tab state" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    _ = testing.model.workspace.active().?.model.removePane(testing.discovered);
    var handler: ConfirmPaneAttachmentHandler = .{ .model = testing.model };
    const attachment = testing.attachment();

    try std.testing.expectEqual(client_model.PaneAttachmentConfirmation.stale, try handler.execute(.{
        .requested = attachment,
        .confirmed = attachment,
        .created = false,
    }));
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "RecoverPaneAttachmentHandler refreshes only an attachment still needed" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RecoveryCapture = .{};
    var handler: RecoverPaneAttachmentHandler = .{
        .model = testing.model,
        .snapshots = capture.handler(),
    };
    const attachment = testing.attachment();

    try std.testing.expect(try handler.execute(attachment));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(testing.location, capture.location.?);

    _ = testing.model.confirmPaneAttachment(attachment);
    try std.testing.expect(!try handler.execute(attachment));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "RecoverPaneAttachmentHandler propagates refresh failure without model mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RecoveryCapture = .{ .fail = true };
    var handler: RecoverPaneAttachmentHandler = .{
        .model = testing.model,
        .snapshots = capture.handler(),
    };

    try std.testing.expectError(error.RefreshFailed, handler.execute(testing.attachment()));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(!testing.model.workspace.findPane(testing.discovered).?.attached);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}
