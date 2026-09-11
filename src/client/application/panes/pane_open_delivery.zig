//! Application routing for one correlated pane-open confirmation.

const TerminalSizeType = @import("telar-core").TerminalSize;
const PaneSplitType = @import("../../model/PaneSplit.zig");
const PaneAttachmentType = @import("../../model/PaneAttachment.zig");
const TabLocationType = @import("telar-core").TabLocation;
const OpenedPane = @import("OpenedPane.zig");
const Command = @import("Command.zig");
const PaneOpenDeliveryCapture = @import("PaneOpenDeliveryCapture.zig");
const DeliverPaneOpenHandler = @import("DeliverPaneOpenHandler.zig");
const std = @import("std");

pub const Continuation = union(enum) {
    initial_open,
    create_workspace: TerminalSizeType,
    split: PaneSplitType,
    attach_pane: PaneAttachmentType,
    ignored,
};

pub const Outcome = enum {
    workspace_arrived,
    workspace_created,
    pane_split,
    pane_attached,
    ignored,
};

pub const Effect = enum {
    arrive_workspace,
    create_workspace,
    confirm_split,
    confirm_attachment,
};

const testing_location: TabLocationType = .{
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
    const requested_size: TerminalSizeType = .{ .cols = 80, .rows = 24 };
    const split: PaneSplitType = .{
        .target_pane = @enumFromInt(4),
        .location = testing_location,
        .axis = .horizontal,
        .area = .{ .w = 40, .h = 10 },
    };
    const attachment: PaneAttachmentType = .{
        .pane_id = testing_opened.pane_id,
        .location = testing_location,
    };
    var capture: PaneOpenDeliveryCapture = .{};
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
    var capture: PaneOpenDeliveryCapture = .{};
    var handler: DeliverPaneOpenHandler = .{ .effects = capture.effects() };

    try std.testing.expectEqual(Outcome.ignored, try handler.execute(testingCommand(.ignored)));
    try std.testing.expect(capture.effect == null);

    capture.failure = .arrive_workspace;
    try std.testing.expectError(error.DeliveryFailed, handler.execute(testingCommand(.initial_open)));
    try std.testing.expectEqual(Effect.arrive_workspace, capture.effect.?);
    try std.testing.expectEqualDeep(testing_opened, capture.opened.?);
}
