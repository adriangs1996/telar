//! Application policy for delivering the irreversible effects produced by one
//! successful host presentation.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../../workspace/root.zig");
const client_model = @import("../../model/root.zig");

const multiplexer = workspace_capability.multiplexer;
const schema = core.schema;

pub const Command = struct {
    commit: multiplexer.PresentationCommit,
    /// Borrowed only for the synchronous delivery.
    frame_acks: []const schema.FrameAck,
    media_pending: bool,
};

pub const Effects = struct {
    context: *anyopaque,
    flush_graphics_credits: *const fn (*anyopaque) anyerror!void,
    acknowledge_frame: *const fn (*anyopaque, schema.FrameAck) anyerror!void,
    request_media: *const fn (*anyopaque) anyerror!void,
};

pub const DeliverPresentationHandler = struct {
    model: *client_model.Model,
    effects: Effects,

    /// Commits one successful host presentation before delivering transport
    /// effects in credits, frame and media order.
    ///
    /// ```zig
    /// try handler.execute(command);
    /// ```
    pub fn execute(handler: *DeliverPresentationHandler, command: Command) !void {
        if (command.commit.len > multiplexer.max_panes) {
            return error.InvalidPresentationCommit;
        }

        if (command.frame_acks.len > multiplexer.max_panes) {
            return error.TooManyFrameAcknowledgements;
        }

        handler.model.commitPresentation(command.commit);
        try handler.effects.flush_graphics_credits(handler.effects.context);

        for (command.frame_acks) |ack| {
            try handler.effects.acknowledge_frame(handler.effects.context, ack);
        }

        if (command.media_pending) {
            try handler.effects.request_media(handler.effects.context);
        }
    }
};

const Event = enum {
    credits,
    acknowledgement,
    media,
};

const Failure = enum {
    none,
    credits,
    second_acknowledgement,
    media,
};

const EffectCapture = struct {
    model: *client_model.Model,
    pane_id: schema.PaneId,
    events: [multiplexer.max_panes + 2]Event = undefined,
    event_count: usize = 0,
    acknowledgements: [multiplexer.max_panes]schema.FrameAck = undefined,
    acknowledgement_count: usize = 0,
    commit_observed: bool = true,
    failure: Failure = .none,

    fn effects(capture: *EffectCapture) Effects {
        return .{
            .context = capture,
            .flush_graphics_credits = flushGraphicsCredits,
            .acknowledge_frame = acknowledgeFrame,
            .request_media = requestMedia,
        };
    }

    fn flushGraphicsCredits(context: *anyopaque) !void {
        const capture: *EffectCapture = @ptrCast(@alignCast(context));
        capture.observeCommit();
        capture.append(.credits);

        if (capture.failure == .credits) {
            return error.CreditFailure;
        }
    }

    fn acknowledgeFrame(context: *anyopaque, ack: schema.FrameAck) !void {
        const capture: *EffectCapture = @ptrCast(@alignCast(context));
        capture.observeCommit();
        capture.append(.acknowledgement);
        capture.acknowledgements[capture.acknowledgement_count] = ack;
        capture.acknowledgement_count += 1;

        if (capture.failure == .second_acknowledgement and capture.acknowledgement_count == 2) {
            return error.AcknowledgementFailure;
        }
    }

    fn requestMedia(context: *anyopaque) !void {
        const capture: *EffectCapture = @ptrCast(@alignCast(context));
        capture.observeCommit();
        capture.append(.media);

        if (capture.failure == .media) {
            return error.MediaFailure;
        }
    }

    fn observeCommit(capture: *EffectCapture) void {
        const pane = capture.model.workspace.findPane(capture.pane_id) orelse {
            capture.commit_observed = false;
            return;
        };

        capture.commit_observed = capture.commit_observed and pane.pending_frame_id == 0;
    }

    fn append(capture: *EffectCapture, event: Event) void {
        capture.events[capture.event_count] = event;
        capture.event_count += 1;
    }

    fn eventSlice(capture: *const EffectCapture) []const Event {
        return capture.events[0..capture.event_count];
    }

    fn acknowledgementSlice(capture: *const EffectCapture) []const schema.FrameAck {
        return capture.acknowledgements[0..capture.acknowledgement_count];
    }
};

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
    commit.len = 1;

    return commit;
}

fn prepareModel(model: *client_model.Model, frame_id: u64) !void {
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 2, .rows = 2 } });
    model.workspace.findPane(pane_id).?.pending_frame_id = frame_id;
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
        .frame_acks = &acknowledgements,
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
    var acknowledgements: [multiplexer.max_panes + 1]schema.FrameAck = undefined;
    @memset(&acknowledgements, .{ .pane_id = pane_id, .frame_id = 7 });

    try std.testing.expectError(error.TooManyFrameAcknowledgements, handler.execute(.{
        .commit = presentationCommit(7),
        .frame_acks = &acknowledgements,
        .media_pending = true,
    }));

    try std.testing.expectEqual(@as(u64, 7), model.workspace.findPane(pane_id).?.pending_frame_id);
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);

    var invalid_commit = presentationCommit(7);
    invalid_commit.len = multiplexer.max_panes + 1;

    try std.testing.expectError(error.InvalidPresentationCommit, handler.execute(.{
        .commit = invalid_commit,
        .frame_acks = &.{},
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
    const acknowledgements = [_]schema.FrameAck{
        .{ .pane_id = pane_id, .frame_id = 7 },
        .{ .pane_id = @enumFromInt(2), .frame_id = 9 },
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
            .frame_acks = &acknowledgements,
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
        .frame_acks = &.{},
        .media_pending = false,
    });

    try std.testing.expectEqualSlices(Event, &.{.credits}, capture.eventSlice());
}
