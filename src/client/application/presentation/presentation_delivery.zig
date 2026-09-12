//! Application policy for delivering the irreversible effects produced by one
//! successful host presentation.

const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const PresentationCommitType = @import("../../panes/PresentationCommit.zig");
const ModelType = @import("../../model/Model.zig");
const std = @import("std");
const EffectCapture = @import("EffectCapture.zig");
const DeliverPresentationHandler = @import("DeliverPresentationHandler.zig");
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;

pub const Event = enum {
    credits,
    media,
};

pub const Failure = enum {
    none,
    credits,
    media,
};

const location: TabLocationType = .{
    .workspace = .{ .workspace = @enumFromInt(1) },
    .tab_id = @enumFromInt(1),
};
const pane_id: PaneIdType = @enumFromInt(1);

fn presentationCommit(frame_id: u64) PresentationCommitType {
    var commit: PresentationCommitType = .{ .location = location };
    commit.panes[0] = .{
        .pane_id = pane_id,
        .frame_id = frame_id,
        .attached = true,
    };
    commit.panes[1] = .{ .pane_id = @enumFromInt(2), .frame_id = 9, .attached = true };
    commit.len = 2;

    return commit;
}

fn prepareModel(model: *ModelType, frame_id: u64) !void {
    try model.workspace.bootstrap(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 2, .rows = 2 } });
    const active = model.workspace.active().?;
    try active.model.split(.{ .existing_pane = pane_id, .new_pane = @enumFromInt(2), .location = location, .axis = .horizontal, .area = .{ .w = 10, .h = 10 } });
    model.workspace.findPane(pane_id).?.pending_frame_id = frame_id;
    model.workspace.findPane(@enumFromInt(2)).?.pending_frame_id = 9;
}

test "DeliverPresentationHandler commits before ordered delivery" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    try prepareModel(&model, 7);
    var capture: EffectCapture = .{ .model = &model, .pane_id = pane_id };
    var handler: DeliverPresentationHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };

    try handler.execute(.{
        .commit = presentationCommit(7),

        .media_pending = true,
    });

    try std.testing.expect(capture.commit_observed);
    try std.testing.expectEqual(@as(u64, 0), model.workspace.findPane(pane_id).?.pending_frame_id);
    try std.testing.expectEqualSlices(Event, &.{ .credits, .media }, capture.eventSlice());
}

test "DeliverPresentationHandler rejects unbounded input before commit" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    try prepareModel(&model, 7);
    var capture: EffectCapture = .{ .model = &model, .pane_id = pane_id };
    var handler: DeliverPresentationHandler = .{
        .model = &model,
        .effects = capture.effects(),
    };
    var invalid_commit = presentationCommit(7);
    invalid_commit.len = max_panes_per_tab + 1;

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
    };
    const scenarios = [_]Scenario{
        .{
            .failure = .credits,
            .expected_error = error.CreditFailure,
            .expected_events = &.{.credits},
        },
        .{
            .failure = .media,
            .expected_error = error.MediaFailure,
            .expected_events = &.{ .credits, .media },
        },
    };
    for (scenarios) |scenario| {
        var model = ModelType.init(std.testing.allocator, true);
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
    }
}

test "DeliverPresentationHandler skips media without pending work" {
    var model = ModelType.init(std.testing.allocator, true);
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

    try std.testing.expectEqualSlices(Event, &.{.credits}, capture.eventSlice());
}
