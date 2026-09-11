//! Application use cases for requesting, confirming and recovering one pane split.

const SplitPaneTestingModel = @import("SplitPaneTestingModel.zig");
const SplitPaneRequestCapture = @import("SplitPaneRequestCapture.zig");
const RequestPaneSplitHandler = @import("RequestPaneSplitHandler.zig");
const std = @import("std");
const VersionType = @import("../../model/Version.zig");
const PaneIdType = @import("telar-core").PaneId;
const ConfirmationCapture = @import("ConfirmationCapture.zig");
const ConfirmPaneSplitHandler = @import("ConfirmPaneSplitHandler.zig");
const types = @import("../../model/types.zig");
const SplitPaneRecoveryCapture = @import("SplitPaneRecoveryCapture.zig");
const RecoverPaneSplitHandler = @import("RecoverPaneSplitHandler.zig");

pub const RecoveryStatus = enum {
    restored,
    not_required,
    stale,
};

pub const RequestStep = enum {
    resize,
    send,
};

test "RequestPaneSplitHandler gates and plans without model mutation" {
    var testing = try SplitPaneTestingModel.init();
    defer testing.deinit();
    var capture: SplitPaneRequestCapture = .{ .blocked = true };
    var handler: RequestPaneSplitHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };

    try std.testing.expect((try handler.execute(.{ .axis = .horizontal, .area = testing.area })) == null);
    try std.testing.expectEqual(@as(usize, 0), capture.recorded().len);
    capture.blocked = false;

    const plan = (try handler.execute(.{ .axis = .horizontal, .area = testing.area })).?;

    try std.testing.expectEqualSlices(RequestStep, &.{ .resize, .send }, capture.recorded());
    try std.testing.expectEqual(testing.pane_id, plan.split.target_pane);
    try std.testing.expectEqualDeep(testing.area, plan.split.area);
    try std.testing.expectEqual(@as(u16, 8), plan.new_pane_size.cell_width_px);
    try std.testing.expectEqual(@as(u16, 16), plan.new_pane_size.cell_height_px);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
    try std.testing.expectEqual(@as(usize, 1), testing.model.workspace.active().?.model.pane_count);
}

test "RequestPaneSplitHandler restores the pre-request size after send failure" {
    var testing = try SplitPaneTestingModel.init();
    defer testing.deinit();
    var capture: SplitPaneRequestCapture = .{ .send_failure = error.SendFailed };
    var handler: RequestPaneSplitHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };

    try std.testing.expectError(error.SendFailed, handler.execute(.{ .axis = .horizontal, .area = testing.area }));

    try std.testing.expectEqualSlices(RequestStep, &.{ .resize, .send, .resize }, capture.recorded());
    try std.testing.expectEqual(testing.pane_id, capture.resizes[1].pane_id);
    try std.testing.expectEqual(@as(u16, testing.area.w), capture.resizes[1].size.cols);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}

test "ConfirmPaneSplitHandler validates and commits before effects" {
    var testing = try SplitPaneTestingModel.init();
    defer testing.deinit();
    const new_pane: PaneIdType = @enumFromInt(2);
    var capture: ConfirmationCapture = .{ .model = testing.model, .pane_id = new_pane };
    var handler: ConfirmPaneSplitHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.UnexpectedPane, handler.execute(.{
        .requested = testing.split(),
        .confirmed_pane = new_pane,
        .confirmed_location = testing.location,
        .created = false,
    }));
    try std.testing.expectEqual(@as(usize, 0), capture.calls);

    const commit = try handler.execute(.{
        .requested = testing.split(),
        .confirmed_pane = new_pane,
        .confirmed_location = testing.location,
        .created = true,
    });

    try std.testing.expectEqual(types.PaneSplitDisposition.active, commit.disposition);
    try std.testing.expectEqual(types.Change.changed, commit.change);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
}

test "ConfirmPaneSplitHandler preserves the commit after effect failure" {
    var testing = try SplitPaneTestingModel.init();
    defer testing.deinit();
    const new_pane: PaneIdType = @enumFromInt(2);
    var capture: ConfirmationCapture = .{
        .model = testing.model,
        .pane_id = new_pane,
        .fail = true,
    };
    var handler: ConfirmPaneSplitHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.SyncFailed, handler.execute(.{
        .requested = testing.split(),
        .confirmed_pane = new_pane,
        .confirmed_location = testing.location,
        .created = true,
    }));

    try std.testing.expect(testing.model.workspace.findPane(new_pane) != null);
    try std.testing.expectEqual(@as(u64, 1), testing.model.version().panes);
    try std.testing.expect(capture.observed_commit);
}

test "RecoverPaneSplitHandler restores only the current active target" {
    var testing = try SplitPaneTestingModel.init();
    defer testing.deinit();
    var capture: SplitPaneRecoveryCapture = .{};
    var handler: RecoverPaneSplitHandler = .{
        .model = testing.model,
        .area = testing.area,
        .effects = capture.port(),
    };

    try std.testing.expectEqual(RecoveryStatus.restored, try handler.execute(testing.split()));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(testing.pane_id, capture.resize_value.?.pane_id);

    _ = testing.model.workspace.active().?.model.removePane(testing.pane_id);
    try std.testing.expectEqual(RecoveryStatus.stale, try handler.execute(testing.split()));
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "RecoverPaneSplitHandler propagates resize failure without model mutation" {
    var testing = try SplitPaneTestingModel.init();
    defer testing.deinit();
    var capture: SplitPaneRecoveryCapture = .{ .fail = true };
    var handler: RecoverPaneSplitHandler = .{
        .model = testing.model,
        .area = testing.area,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.ResizeFailed, handler.execute(testing.split()));

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(VersionType{}, testing.model.version());
}
