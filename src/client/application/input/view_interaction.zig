//! Application policy for dispatching one semantic view interaction.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../root.zig").agents;
const attachments = @import("../../attachments/root.zig");
const notification_capability = @import("../../root.zig").notifications;

const schema = core.schema;

pub const Intent = union(enum) {
    none,
    toggle_sidebar,
    resize_sidebar: u16,
    toggle_workspace_list,
    focus_agent: agents.AgentKey,
    select_tab: schema.TabId,
    focus_pane: schema.PaneId,
    rename_tab: schema.TabId,
    select_workspace: schema.WorkspaceId,
    notification_activate: notification_capability.Id,
    notification_dismiss: notification_capability.Id,
    attachment_dismiss: attachments.Id,
};

pub const Command = @import("ViewInteractionCommand.zig");

pub const Outcome = @import("ViewInteractionOutcome.zig");

pub const IntentOutcome = @import("IntentOutcome.zig");

pub const Effects = @import("ViewInteractionEffects.zig");

pub const DispatchViewInteractionHandler = @import("DispatchViewInteractionHandler.zig");

pub fn capturesPaneInput(intent: Intent) bool {
    return switch (intent) {
        .select_tab, .focus_agent => true,
        else => false,
    };
}

pub const Event = union(enum) {
    intent: Intent,
    invalidate_graphics_placements,
    offer_pane_geometry,
};

pub const Failure = enum {
    none,
    intent,
    pane_geometry,
};

const Capture = @import("ViewInteractionCapture.zig");

test "DispatchViewInteractionHandler orders intent invalidation and pane geometry" {
    const key: agents.AgentKey = .{
        .pane_id = @enumFromInt(3),
        .pane_generation = 7,
    };
    var capture: Capture = .{};
    var handler: DispatchViewInteractionHandler = .{ .effects = capture.effects() };

    const outcome = try handler.execute(.{
        .intent = .{ .focus_agent = key },
        .layout_changed = true,
    });

    try std.testing.expectEqualDeep(Outcome{
        .consume_pane_input = true,
    }, outcome);
    try std.testing.expectEqual(@as(usize, 3), capture.count);
    try std.testing.expectEqualDeep(Intent{ .focus_agent = key }, capture.events[0].intent);
    try std.testing.expect(capture.events[1] == .invalidate_graphics_placements);
    try std.testing.expect(capture.events[2] == .offer_pane_geometry);
}

test "attachment dismissal can discover its layout change while applying the intent" {
    var capture: Capture = .{};
    var handler: DispatchViewInteractionHandler = .{ .effects = capture.effects() };
    const id: attachments.Id = @enumFromInt(4);

    _ = try handler.execute(.{ .intent = .{ .attachment_dismiss = id } });

    try std.testing.expectEqual(@as(usize, 3), capture.count);
    try std.testing.expectEqualDeep(Intent{ .attachment_dismiss = id }, capture.events[0].intent);
    try std.testing.expect(capture.events[1] == .invalidate_graphics_placements);
    try std.testing.expect(capture.events[2] == .offer_pane_geometry);
}

test "DispatchViewInteractionHandler preserves completed stages across failures" {
    var capture: Capture = .{ .failure = .intent };
    var handler: DispatchViewInteractionHandler = .{ .effects = capture.effects() };
    const command: Command = .{
        .intent = .{ .rename_tab = @enumFromInt(4) },
        .layout_changed = true,
    };

    try std.testing.expectError(error.ViewIntentFailed, handler.execute(command));
    try std.testing.expectEqual(@as(usize, 1), capture.count);

    capture = .{ .failure = .pane_geometry };
    handler = .{ .effects = capture.effects() };
    try std.testing.expectError(error.PaneGeometryFailed, handler.execute(command));
    try std.testing.expectEqual(@as(usize, 3), capture.count);
    try std.testing.expect(capture.events[1] == .invalidate_graphics_placements);
    try std.testing.expect(capture.events[2] == .offer_pane_geometry);
}

test "DispatchViewInteractionHandler delivers layout without a semantic intent" {
    var capture: Capture = .{};
    var handler: DispatchViewInteractionHandler = .{ .effects = capture.effects() };

    const outcome = try handler.execute(.{ .layout_changed = true, .consumed = true });

    try std.testing.expect(outcome.consume_pane_input);
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expect(capture.events[0] == .invalidate_graphics_placements);
    try std.testing.expect(capture.events[1] == .offer_pane_geometry);
}

test "DispatchViewInteractionHandler owns pane-input capture policy" {
    const cases = [_]struct {
        command: Command,
        consume: bool,
    }{
        .{ .command = .{}, .consume = false },
        .{ .command = .{ .consumed = true }, .consume = true },
        .{ .command = .{ .intent = .{ .select_tab = @enumFromInt(2) } }, .consume = true },
        .{ .command = .{ .intent = .{ .focus_agent = .{
            .pane_id = @enumFromInt(3),
            .pane_generation = 1,
        } } }, .consume = true },
        .{ .command = .{ .intent = .{ .focus_pane = @enumFromInt(4) } }, .consume = false },
        .{ .command = .{ .intent = .toggle_sidebar }, .consume = false },
    };

    for (cases) |case| {
        var capture: Capture = .{};
        var handler: DispatchViewInteractionHandler = .{ .effects = capture.effects() };

        const outcome = try handler.execute(case.command);

        try std.testing.expectEqual(case.consume, outcome.consume_pane_input);
    }
}
