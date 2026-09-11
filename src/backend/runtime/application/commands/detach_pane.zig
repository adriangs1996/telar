//! Application command for removing one pane from a client session.

const PaneDetachedType = @import("../../attachment/PaneDetached.zig");
const pane_module = @import("telar-core").pane;
const workspace_module = @import("telar-core").workspace;
const Capture = @import("Capture.zig");
const DetachPaneHandler = @import("DetachPaneHandler.zig");
const std = @import("std");

pub const DetachPaneResult = enum {
    detached,
    not_attached,
};

pub const Effect = enum {
    detach,
    leave_workspace,
    release,
};

fn testingDetached(last_attachment: bool) !PaneDetachedType {
    return .{
        .pane_id = try pane_module(7),
        .workspace = .{ .workspace = try workspace_module(3) },
        .last_attachment = last_attachment,
    };
}

test "DetachPaneHandler leaves missing attachments and geometry unchanged" {
    var capture: Capture = .{};
    var handler: DetachPaneHandler = .{
        .attachments = capture.attachments(),
        .geometry = capture.geometry(),
    };
    const pane_id = try pane_module(7);

    const result = try handler.execute(.{ .pane_id = pane_id });

    try std.testing.expectEqual(DetachPaneResult.not_attached, result);
    try std.testing.expectEqual(pane_id, capture.requested_pane);
    try std.testing.expectEqual(@as(usize, 1), capture.effect_count);
    try std.testing.expectEqual(Effect.detach, capture.effects[0]);
    try std.testing.expect(capture.released_workspace == null);
}

test "DetachPaneHandler keeps geometry while another pane observes the workspace" {
    var capture: Capture = .{ .detached = try testingDetached(false) };
    var handler: DetachPaneHandler = .{
        .attachments = capture.attachments(),
        .geometry = capture.geometry(),
    };

    const result = try handler.execute(.{ .pane_id = capture.detached.?.pane_id });

    try std.testing.expectEqual(DetachPaneResult.detached, result);
    try std.testing.expectEqual(@as(usize, 1), capture.effect_count);
    try std.testing.expect(capture.released_workspace == null);
}

test "DetachPaneHandler releases geometry after leaving the workspace" {
    var capture: Capture = .{ .detached = try testingDetached(true) };
    var handler: DetachPaneHandler = .{
        .attachments = capture.attachments(),
        .geometry = capture.geometry(),
    };

    const result = try handler.execute(.{ .pane_id = capture.detached.?.pane_id });

    try std.testing.expectEqual(DetachPaneResult.detached, result);
    try std.testing.expectEqual(@as(usize, 3), capture.effect_count);
    try std.testing.expectEqual(Effect.detach, capture.effects[0]);
    try std.testing.expectEqual(Effect.leave_workspace, capture.effects[1]);
    try std.testing.expectEqual(Effect.release, capture.effects[2]);
    try std.testing.expectEqualDeep(capture.detached.?.workspace, capture.released_workspace.?);
}

test "DetachPaneHandler does not release geometry after a workspace state conflict" {
    var capture: Capture = .{
        .detached = try testingDetached(true),
        .leave_allowed = false,
    };
    var handler: DetachPaneHandler = .{
        .attachments = capture.attachments(),
        .geometry = capture.geometry(),
    };

    try std.testing.expectError(error.AttachmentStateConflict, handler.execute(.{
        .pane_id = capture.detached.?.pane_id,
    }));

    try std.testing.expectEqual(@as(usize, 2), capture.effect_count);
    try std.testing.expectEqual(Effect.detach, capture.effects[0]);
    try std.testing.expectEqual(Effect.leave_workspace, capture.effects[1]);
    try std.testing.expect(capture.released_workspace == null);
}
