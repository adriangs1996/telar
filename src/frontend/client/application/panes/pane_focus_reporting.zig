//! Application policy for child terminal focus reporting and retirement.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");

const schema = core.schema;

pub const Command = enum {
    sync,
    clear,
};

pub const Direction = enum {
    focus_out,
    focus_in,
};

pub const Delivery = struct {
    pane_id: schema.PaneId,
    direction: Direction,
};

pub const Effects = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, Delivery) anyerror!void,
};

pub const Outcome = enum {
    applied,
    unchanged,
};

pub const PaneFocusReportingHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Commits one reporting transition before emitting focus-out and
    /// focus-in in protocol order.
    ///
    /// ```zig
    /// _ = try handler.execute(.sync);
    /// ```
    pub fn execute(handler: *PaneFocusReportingHandler, command: Command) !Outcome {
        const transition = switch (command) {
            .sync => handler.model.syncReportedPaneFocus(),
            .clear => handler.model.clearReportedPaneFocus(),
        } orelse return .unchanged;

        if (transition.focus_out) |pane_id| {
            try handler.effects.deliver(handler.effects.context, .{
                .pane_id = pane_id,
                .direction = .focus_out,
            });
        }

        if (transition.focus_in) |pane_id| {
            try handler.effects.deliver(handler.effects.context, .{
                .pane_id = pane_id,
                .direction = .focus_in,
            });
        }

        return .applied;
    }
};

pub const RetireReportedPaneFocusHandler = struct {
    model: *client_model.Model,

    /// Forgets focus reporting after a canonical transition invalidates its
    /// owner. This use case has no delivery port and cannot emit focus-out.
    ///
    /// ```zig
    /// _ = handler.execute();
    /// ```
    pub fn execute(handler: *RetireReportedPaneFocusHandler) Outcome {
        return if (handler.model.forgetReportedPaneFocus()) .applied else .unchanged;
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    first: schema.PaneId,
    second: schema.PaneId,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();

        const location: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        const first: schema.PaneId = @enumFromInt(1);
        const second: schema.PaneId = @enumFromInt(2);
        try model.workspace.bootstrap(.{ .pane_id = first, .location = location, .size = .{ .cols = 80, .rows = 24 } });
        try model.workspace.active().?.model.split(.{ .existing_pane = first, .new_pane = second, .location = location, .axis = .horizontal, .area = .{ .w = 80, .h = 24 } });
        try std.testing.expect(model.workspace.active().?.model.focusPane(first));

        return .{ .model = model, .first = first, .second = second };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

const Capture = struct {
    model: *const client_model.Model,
    expected: ?client_model.ReportedPaneFocus,
    deliveries: [4]Delivery = undefined,
    delivery_count: usize = 0,
    all_observed_commit: bool = true,
    fail: bool = false,

    fn port(capture: *Capture) Effects {
        return .{ .context = capture, .deliver = deliver };
    }

    fn deliver(raw_context: *anyopaque, delivery: Delivery) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.all_observed_commit = capture.all_observed_commit and
            std.meta.eql(capture.expected, capture.model.reportedPaneFocus());
        capture.deliveries[capture.delivery_count] = delivery;
        capture.delivery_count += 1;

        if (capture.fail) {
            return error.FocusReportFailed;
        }
    }
};

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
