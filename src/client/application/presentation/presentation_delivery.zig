//! Application policy for delivering the irreversible effects produced by one
//! successful host presentation.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../workspace/root.zig");
const client_model = @import("../../root.zig").model;

pub const multiplexer = workspace_capability.multiplexer;
pub const schema = core.schema;

pub const Command = @import("Command.zig");

pub const Effects = @import("Effects.zig");

pub const DeliverPresentationHandler = @import("DeliverPresentationHandler.zig");

pub const Event = enum {
    credits,
    acknowledgement,
    media,
};

pub const Failure = enum {
    none,
    credits,
    second_acknowledgement,
    media,
};

const EffectCapture = @import("EffectCapture.zig");

const location: schema.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(1) },
    .tab_id = @enumFromInt(1),
};
const pane_id: schema.PaneId = @enumFromInt(1);

fn presentationCommit(frame_id: u64) multiplexer.PresentationCommit {
    var commit: multiplexer.PresentationCommit = .{ .location = location };
    commit.panes[0] = .{
        .pane_id = pane_id,
        .frame_id = frame_id,
        .attached = true,
    };
    commit.panes[1] = .{ .pane_id = @enumFromInt(2), .frame_id = 9, .attached = true };
    commit.len = 2;

    return commit;
}

fn prepareModel(model: *client_model.Model, frame_id: u64) !void {
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 2, .rows = 2 } });
    const active = model.workspace.active().?;
    try active.model.split(.{ .existing_pane = pane_id, .new_pane = @enumFromInt(2), .location = location, .axis = .horizontal, .area = .{ .w = 10, .h = 10 } });
    model.workspace.findPane(pane_id).?.pending_frame_id = frame_id;
    model.workspace.findPane(@enumFromInt(2)).?.pending_frame_id = 9;
}

test "DeliverPresentationHandler commits before ordered delivery" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    try prepareModel(&model, 7);
    var capture: EffectCapture = .{ .model = &model, .pane_id = pane_id };
    var handler: DeliverPresentationHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };
    const acknowledgements = [_]schema.FrameAck{
        .{ .pane_id = pane_id, .frame_id = 7 },
        .{ .pane_id = @enumFromInt(2), .frame_id = 9 },
    };

    try handler.execute(.{
        .commit = presentationCommit(7),

        .media_pending = true,
    });

    try std.testing.expect(capture.commit_observed);
    try std.testing.expectEqual(@as(u64, 0), model.workspace.findPane(pane_id).?.pending_frame_id);
    try std.testing.expectEqualSlices(Event, &.{ .credits, .acknowledgement, .acknowledgement, .media }, capture.eventSlice());
    try std.testing.expectEqualSlices(schema.FrameAck, &acknowledgements, capture.acknowledgementSlice());
}

test "DeliverPresentationHandler rejects unbounded input before commit" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    try prepareModel(&model, 7);
    var capture: EffectCapture = .{ .model = &model, .pane_id = pane_id };
    var handler: DeliverPresentationHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };
    var invalid_commit = presentationCommit(7);
    invalid_commit.len = multiplexer.max_panes + 1;

    try std.testing.expectError(error.InvalidPresentationCommit, handler.execute(.{
        .commit = invalid_commit,

        .media_pending = false,
    }));

    try std.testing.expectEqual(@as(u64, 7), model.workspace.findPane(pane_id).?.pending_frame_id);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverPresentationHandler preserves applied effects across delivery failures" {
    const Scenario = struct {
        failure: Failure,
        expected_error: anyerror,
        expected_events: []const Event,
        expected_acknowledgements: usize,
    };
    const scenarios = [_]Scenario{
        .{
            .failure = .credits,
            .expected_error = error.CreditFailure,
            .expected_events = &.{.credits},
            .expected_acknowledgements = 0,
        },
        .{
            .failure = .second_acknowledgement,
            .expected_error = error.AcknowledgementFailure,
            .expected_events = &.{ .credits, .acknowledgement, .acknowledgement },
            .expected_acknowledgements = 2,
        },
        .{
            .failure = .media,
            .expected_error = error.MediaFailure,
            .expected_events = &.{ .credits, .acknowledgement, .acknowledgement, .media },
            .expected_acknowledgements = 2,
        },
    };
    for (scenarios) |scenario| {
        var model = client_model.Model.init(std.testing.allocator, true);
        defer model.deinit();
        try prepareModel(&model, 7);
        var capture: EffectCapture = .{
            .model = &model,
            .pane_id = pane_id,
            .failure = scenario.failure,
        };
        var handler: DeliverPresentationHandler = .{
            .model = &model,
            .effects = capture.effects(),
        };

        try std.testing.expectError(scenario.expected_error, handler.execute(.{
            .commit = presentationCommit(7),

            .media_pending = true,
        }));

        try std.testing.expect(capture.commit_observed);
        try std.testing.expectEqual(@as(u64, 0), model.workspace.findPane(pane_id).?.pending_frame_id);
        try std.testing.expectEqualSlices(Event, scenario.expected_events, capture.eventSlice());
        try std.testing.expectEqual(scenario.expected_acknowledgements, capture.acknowledgement_count);
    }
}

test "DeliverPresentationHandler skips media without pending work" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    try prepareModel(&model, 7);
    var capture: EffectCapture = .{ .model = &model, .pane_id = pane_id };
    var handler: DeliverPresentationHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try handler.execute(.{
        .commit = presentationCommit(7),

        .media_pending = false,
    });

    try std.testing.expectEqualSlices(Event, &.{ .credits, .acknowledgement, .acknowledgement }, capture.eventSlice());
}
