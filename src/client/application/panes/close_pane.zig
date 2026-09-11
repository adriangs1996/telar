//! Client use cases for requesting pane closure and applying pane exit.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;

pub const PaneClosure = client_model.PaneClosure;
pub const PaneExit = client_model.PaneExit;

pub const PaneOperationGate = @import("ClosePanePaneOperationGate.zig");

pub const CloseRequestEffects = @import("CloseRequestEffects.zig");

pub const RequestClosePaneHandler = @import("RequestClosePaneHandler.zig");

pub const PaneExitEffects = @import("PaneExitEffects.zig");

pub const HandlePaneExitHandler = @import("HandlePaneExitHandler.zig");

const TestingModel = @import("ClosePaneTestingModel.zig");

const RequestCapture = @import("ClosePaneRequestCapture.zig");

const ExitCapture = @import("ExitCapture.zig");

test "RequestClosePaneHandler gates and sends without model mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .blocked = true };
    var handler: RequestClosePaneHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };

    try std.testing.expect((try handler.execute()) == null);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    capture.blocked = false;

    const closure = (try handler.execute()).?;

    try std.testing.expectEqual(testing.pane_id, closure.pane_id);
    try std.testing.expectEqualDeep(testing.location, closure.location);
    try std.testing.expectEqualDeep(closure, capture.closure.?);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
    try std.testing.expect(testing.model.workspace.findPane(testing.pane_id) != null);
}

test "RequestClosePaneHandler rejects detached panes before effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    testing.model.workspace.findPane(testing.pane_id).?.attached = false;
    var capture: RequestCapture = .{};
    var handler: RequestClosePaneHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };

    try std.testing.expect((try handler.execute()) == null);

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "RequestClosePaneHandler propagates delivery failure without model mutation" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: RequestCapture = .{ .fail = true };
    var handler: RequestClosePaneHandler = .{
        .model = testing.model,
        .gate = capture.gate(),
        .effects = capture.port(),
    };

    try std.testing.expectError(error.SendFailed, handler.execute());

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(testing.model.workspace.findPane(testing.pane_id) != null);
    try std.testing.expectEqualDeep(client_model.Version{}, testing.model.version());
}

test "HandlePaneExitHandler commits before cleanup" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: ExitCapture = .{ .model = testing.model, .pane_id = testing.pane_id };
    var handler: HandlePaneExitHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    const transition = try handler.execute(testing.pane_id);

    try std.testing.expect(transition == .retired);
    try std.testing.expect(transition.retired.active);
    try std.testing.expect(transition.retired.tab_empty);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.observed_commit);
}

test "HandlePaneExitHandler preserves a committed exit after cleanup failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: ExitCapture = .{
        .model = testing.model,
        .pane_id = testing.pane_id,
        .fail = true,
    };
    var handler: HandlePaneExitHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.CleanupFailed, handler.execute(testing.pane_id));

    try std.testing.expect(testing.model.workspace.findPane(testing.pane_id) == null);
    try std.testing.expectEqualDeep(client_model.Version{ .panes = 1 }, testing.model.version());
    try std.testing.expect(capture.observed_commit);
}

test "HandlePaneExitHandler applies idempotent cleanup to stale exits" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    _ = testing.model.retirePane(testing.pane_id);
    var capture: ExitCapture = .{ .model = testing.model, .pane_id = testing.pane_id };
    var handler: HandlePaneExitHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };
    const version_before = testing.model.version();

    const transition = try handler.execute(testing.pane_id);

    try std.testing.expect(transition == .stale);
    try std.testing.expectEqual(testing.pane_id, transition.stale.pane_id);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(version_before, testing.model.version());
}
