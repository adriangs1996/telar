//! Application routing for one correlated pane-open confirmation.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../model/root.zig");

const schema = core.schema;

pub const OpenedPane = struct {
    pane_id: schema.PaneId,
    location: schema.TabLocation,
    created: bool,
};

pub const Continuation = union(enum) {
    initial_open,
    create_workspace: schema.TerminalSize,
    split: client_model.PaneSplit,
    attach_pane: client_model.PaneAttachment,
    ignored,
};

pub const Command = struct {
    continuation: Continuation,
    opened: OpenedPane,
};

pub const WorkspaceCreation = struct {
    requested_size: schema.TerminalSize,
    opened: OpenedPane,
};

pub const PaneSplitConfirmation = struct {
    requested: client_model.PaneSplit,
    opened: OpenedPane,
};

pub const PaneAttachmentConfirmation = struct {
    requested: client_model.PaneAttachment,
    opened: OpenedPane,
};

pub const Effects = struct {
    context: *anyopaque,
    arrive_workspace: *const fn (*anyopaque, OpenedPane) anyerror!void,
    create_workspace: *const fn (*anyopaque, WorkspaceCreation) anyerror!void,
    confirm_split: *const fn (*anyopaque, PaneSplitConfirmation) anyerror!void,
    confirm_attachment: *const fn (*anyopaque, PaneAttachmentConfirmation) anyerror!void,
};

pub const Outcome = enum {
    workspace_arrived,
    workspace_created,
    pane_split,
    pane_attached,
    ignored,
};

pub const DeliverPaneOpenHandler = struct {
    effects: Effects,

    /// Routes one already-correlated confirmation to its exact application
    /// flow. Retired work has no effects.
    ///
    /// ```zig
    /// const outcome = try handler.execute(command);
    /// ```
    pub fn execute(handler: *DeliverPaneOpenHandler, command: Command) !Outcome {
        return switch (command.continuation) {
            .initial_open => delivery: {
                try handler.effects.arrive_workspace(handler.effects.context, command.opened);
                break :delivery .workspace_arrived;
            },
            .create_workspace => |requested_size| delivery: {
                try handler.effects.create_workspace(handler.effects.context, .{
                    .requested_size = requested_size,
                    .opened = command.opened,
                });
                break :delivery .workspace_created;
            },
            .split => |requested| delivery: {
                try handler.effects.confirm_split(handler.effects.context, .{
                    .requested = requested,
                    .opened = command.opened,
                });
                break :delivery .pane_split;
            },
            .attach_pane => |requested| delivery: {
                try handler.effects.confirm_attachment(handler.effects.context, .{
                    .requested = requested,
                    .opened = command.opened,
                });
                break :delivery .pane_attached;
            },
            .ignored => .ignored,
        };
    }
};

const Effect = enum {
    arrive_workspace,
    create_workspace,
    confirm_split,
    confirm_attachment,
};

const Capture = struct {
    effect: ?Effect = null,
    opened: ?OpenedPane = null,
    requested_size: ?schema.TerminalSize = null,
    split: ?client_model.PaneSplit = null,
    attachment: ?client_model.PaneAttachment = null,
    failure: ?Effect = null,

    fn effects(capture: *Capture) Effects {
        return .{
            .context = capture,
            .arrive_workspace = arriveWorkspace,
            .create_workspace = createWorkspace,
            .confirm_split = confirmSplit,
            .confirm_attachment = confirmAttachment,
        };
    }

    fn arriveWorkspace(raw_context: *anyopaque, opened: OpenedPane) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        try capture.record(.arrive_workspace, opened);
    }

    fn createWorkspace(raw_context: *anyopaque, confirmation: WorkspaceCreation) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.requested_size = confirmation.requested_size;
        try capture.record(.create_workspace, confirmation.opened);
    }

    fn confirmSplit(raw_context: *anyopaque, confirmation: PaneSplitConfirmation) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.split = confirmation.requested;
        try capture.record(.confirm_split, confirmation.opened);
    }

    fn confirmAttachment(raw_context: *anyopaque, confirmation: PaneAttachmentConfirmation) !void {
        const capture: *Capture = @ptrCast(@alignCast(raw_context));
        capture.attachment = confirmation.requested;
        try capture.record(.confirm_attachment, confirmation.opened);
    }

    fn record(capture: *Capture, effect: Effect, opened: OpenedPane) !void {
        capture.effect = effect;
        capture.opened = opened;

        if (capture.failure == effect) {
            return error.DeliveryFailed;
        }
    }

    fn reset(capture: *Capture) void {
        capture.effect = null;
        capture.opened = null;
        capture.requested_size = null;
        capture.split = null;
        capture.attachment = null;
    }
};

const testing_location: schema.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(1) },
    .tab_id = @enumFromInt(2),
};

const testing_opened: OpenedPane = .{
    .pane_id = @enumFromInt(3),
    .location = testing_location,
    .created = true,
};

fn testingCommand(continuation: Continuation) Command {
    return .{ .continuation = continuation, .opened = testing_opened };
}

test "DeliverPaneOpenHandler routes every live continuation exactly once" {
    const requested_size: schema.TerminalSize = .{ .cols = 80, .rows = 24 };
    const split: client_model.PaneSplit = .{
        .target_pane = @enumFromInt(4),
        .location = testing_location,
        .axis = .horizontal,
        .area = .{ .w = 40, .h = 10 },
    };
    const attachment: client_model.PaneAttachment = .{
        .pane_id = testing_opened.pane_id,
        .location = testing_location,
    };
    var capture: Capture = .{};
    var handler: DeliverPaneOpenHandler = .{ .effects = capture.effects() };

    try std.testing.expectEqual(Outcome.workspace_arrived, try handler.execute(testingCommand(.initial_open)));
    try std.testing.expectEqual(Effect.arrive_workspace, capture.effect.?);
    try std.testing.expectEqualDeep(testing_opened, capture.opened.?);

    capture.reset();
    try std.testing.expectEqual(Outcome.workspace_created, try handler.execute(testingCommand(.{ .create_workspace = requested_size })));
    try std.testing.expectEqual(Effect.create_workspace, capture.effect.?);
    try std.testing.expectEqualDeep(requested_size, capture.requested_size.?);
    try std.testing.expectEqualDeep(testing_opened, capture.opened.?);

    capture.reset();
    try std.testing.expectEqual(Outcome.pane_split, try handler.execute(testingCommand(.{ .split = split })));
    try std.testing.expectEqual(Effect.confirm_split, capture.effect.?);
    try std.testing.expectEqualDeep(split, capture.split.?);
    try std.testing.expectEqualDeep(testing_opened, capture.opened.?);

    capture.reset();
    try std.testing.expectEqual(Outcome.pane_attached, try handler.execute(testingCommand(.{ .attach_pane = attachment })));
    try std.testing.expectEqual(Effect.confirm_attachment, capture.effect.?);
    try std.testing.expectEqualDeep(attachment, capture.attachment.?);
    try std.testing.expectEqualDeep(testing_opened, capture.opened.?);
}

test "DeliverPaneOpenHandler ignores retired work and propagates delivery failure" {
    var capture: Capture = .{};
    var handler: DeliverPaneOpenHandler = .{ .effects = capture.effects() };

    try std.testing.expectEqual(Outcome.ignored, try handler.execute(testingCommand(.ignored)));
    try std.testing.expect(capture.effect == null);

    capture.failure = .arrive_workspace;
    try std.testing.expectError(error.DeliveryFailed, handler.execute(testingCommand(.initial_open)));
    try std.testing.expectEqual(Effect.arrive_workspace, capture.effect.?);
    try std.testing.expectEqualDeep(testing_opened, capture.opened.?);
}
