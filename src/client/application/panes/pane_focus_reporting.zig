//! Application policy for child terminal focus reporting and retirement.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;

pub const Command = enum {
    sync,
    clear,
};

pub const Direction = enum {
    focus_out,
    focus_in,
};

pub const Delivery = @import("Delivery.zig");

pub const Effects = @import("PaneFocusReportingEffects.zig");

pub const Outcome = enum {
    applied,
    unchanged,
};

pub const PaneFocusReportingHandler = @import("PaneFocusReportingHandler.zig");

pub const RetireReportedPaneFocusHandler = @import("RetireReportedPaneFocusHandler.zig");

const TestingModel = @import("PaneFocusReportingTestingModel.zig");

const Capture = @import("PaneFocusReportingCapture.zig");

test "PaneFocusReportingHandler commits before ordered focus reports" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const first_pane = testing.model.workspace.findPane(testing.first).?;
    const second_pane = testing.model.workspace.findPane(testing.second).?;
    first_pane.input_modes.focus_events = true;
    second_pane.input_modes.focus_events = true;
    var capture: Capture = .{
        .model = testing.model,
        .expected = .{ .pane_id = testing.first, .focus_events = true },
    };
    var handler: PaneFocusReportingHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expect(try handler.execute(.sync) == .applied);
    try std.testing.expect(testing.model.workspace.active().?.model.focusPane(testing.second));
    capture.expected = .{ .pane_id = testing.second, .focus_events = true };
    try std.testing.expect(try handler.execute(.sync) == .applied);

    try std.testing.expectEqual(@as(usize, 3), capture.delivery_count);
    try std.testing.expect(capture.all_observed_commit);
    try std.testing.expectEqualDeep(Delivery{
        .pane_id = testing.first,
        .direction = .focus_in,
    }, capture.deliveries[0]);
    try std.testing.expectEqualDeep(Delivery{
        .pane_id = testing.first,
        .direction = .focus_out,
    }, capture.deliveries[1]);
    try std.testing.expectEqualDeep(Delivery{
        .pane_id = testing.second,
        .direction = .focus_in,
    }, capture.deliveries[2]);
}

test "PaneFocusReportingHandler commits disabled reporting without effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    const version = testing.model.version();
    var capture: Capture = .{
        .model = testing.model,
        .expected = .{ .pane_id = testing.first, .focus_events = false },
    };
    var handler: PaneFocusReportingHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expect(try handler.execute(.sync) == .applied);
    try std.testing.expect(try handler.execute(.sync) == .unchanged);

    try std.testing.expectEqual(@as(usize, 0), capture.delivery_count);
    try std.testing.expectEqualDeep(version, testing.model.version());
    try std.testing.expectEqualDeep(capture.expected.?, testing.model.reportedPaneFocus().?);
}

test "PaneFocusReportingHandler preserves committed target after delivery failure" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    testing.model.workspace.findPane(testing.first).?.input_modes.focus_events = true;
    testing.model.workspace.findPane(testing.second).?.input_modes.focus_events = true;
    _ = testing.model.syncReportedPaneFocus().?;
    try std.testing.expect(testing.model.workspace.active().?.model.focusPane(testing.second));
    const expected = client_model.ReportedPaneFocus{
        .pane_id = testing.second,
        .focus_events = true,
    };
    var capture: Capture = .{
        .model = testing.model,
        .expected = expected,
        .fail = true,
    };
    var handler: PaneFocusReportingHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expectError(error.FocusReportFailed, handler.execute(.sync));

    try std.testing.expectEqualDeep(expected, testing.model.reportedPaneFocus().?);
    try std.testing.expectEqual(@as(usize, 1), capture.delivery_count);
    try std.testing.expect(capture.deliveries[0].direction == .focus_out);
    try std.testing.expect(capture.all_observed_commit);
}

test "PaneFocusReportingHandler clears one reporting owner exactly once" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    testing.model.workspace.findPane(testing.first).?.input_modes.focus_events = true;
    _ = testing.model.syncReportedPaneFocus().?;
    var capture: Capture = .{ .model = testing.model, .expected = null };
    var handler: PaneFocusReportingHandler = .{
        .model = testing.model,
        .effects = capture.port(),
    };

    try std.testing.expect(try handler.execute(.clear) == .applied);
    try std.testing.expect(try handler.execute(.clear) == .unchanged);

    try std.testing.expect(testing.model.reportedPaneFocus() == null);
    try std.testing.expectEqual(@as(usize, 1), capture.delivery_count);
    try std.testing.expect(capture.deliveries[0].direction == .focus_out);
    try std.testing.expect(capture.all_observed_commit);
}

test "RetireReportedPaneFocusHandler silently forgets one stale owner" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    testing.model.workspace.findPane(testing.first).?.input_modes.focus_events = true;
    _ = testing.model.syncReportedPaneFocus().?;
    const version = testing.model.version();
    var handler: RetireReportedPaneFocusHandler = .{ .model = testing.model };

    try std.testing.expect(handler.execute() == .applied);
    try std.testing.expect(handler.execute() == .unchanged);

    try std.testing.expect(testing.model.reportedPaneFocus() == null);
    try std.testing.expectEqual(testing.first, testing.model.workspace.active().?.model.layout.focused().?);
    try std.testing.expectEqualDeep(version, testing.model.version());
}
