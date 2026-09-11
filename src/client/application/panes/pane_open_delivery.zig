//! Application routing for one correlated pane-open confirmation.

const std = @import("std");
const core = @import("telar-core");
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;

pub const OpenedPane = @import("OpenedPane.zig");

pub const Continuation = union(enum) {
    initial_open,
    create_workspace: schema.TerminalSize,
    split: client_model.PaneSplit,
    attach_pane: client_model.PaneAttachment,
    ignored,
};

pub const Command = @import("Command.zig");

pub const WorkspaceCreation = @import("WorkspaceCreation.zig");

pub const PaneSplitConfirmation = @import("PaneSplitConfirmation.zig");

pub const PaneAttachmentConfirmation = @import("PaneAttachmentConfirmation.zig");

pub const Effects = @import("PaneOpenDeliveryEffects.zig");

pub const Outcome = enum {
    workspace_arrived,
    workspace_created,
    pane_split,
    pane_attached,
    ignored,
};

pub const DeliverPaneOpenHandler = @import("DeliverPaneOpenHandler.zig");

pub const Effect = enum {
    arrive_workspace,
    create_workspace,
    confirm_split,
    confirm_attachment,
};

const Capture = @import("PaneOpenDeliveryCapture.zig");

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
