//! Application policy for dispatching one semantic view interaction.

const AgentKeyType = @import("../../agents/AgentKey.zig");
const TabIdType = @import("telar-core").TabId;
const PaneIdType = @import("telar-core").PaneId;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const notification_capability = @import("../../notifications/notifications.zig");
const types = @import("../../attachments/types.zig");
const ViewInteractionCapture = @import("ViewInteractionCapture.zig");
const DispatchViewInteractionHandler = @import("DispatchViewInteractionHandler.zig");
const std = @import("std");
const ViewInteractionOutcome = @import("ViewInteractionOutcome.zig");
const ViewInteractionCommand = @import("ViewInteractionCommand.zig");

pub const Intent = union(enum) {
    none,
    toggle_sidebar,
    resize_sidebar: u16,
    toggle_workspace_list,
    focus_agent: AgentKeyType,
    select_tab: TabIdType,
    focus_pane: PaneIdType,
    rename_tab: TabIdType,
    select_workspace: WorkspaceIdType,
    notification_activate: notification_capability.Id,
    notification_dismiss: notification_capability.Id,
    attachment_dismiss: types.Id,
};

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

test "DispatchViewInteractionHandler orders intent invalidation and pane geometry" {
    const key: AgentKeyType = .{
        .pane_id = @enumFromInt(3),
        .pane_generation = 7,
    };
    var capture: ViewInteractionCapture = .{};
    var handler: DispatchViewInteractionHandler = .{ .effects = capture.effects() };

    const outcome = try handler.execute(.{
        .intent = .{ .focus_agent = key },
        .layout_changed = true,
    });

    try std.testing.expectEqualDeep(ViewInteractionOutcome{
        .consume_pane_input = true,
    }, outcome);
    try std.testing.expectEqual(@as(usize, 3), capture.count);
    try std.testing.expectEqualDeep(Intent{ .focus_agent = key }, capture.events[0].intent);
    try std.testing.expect(capture.events[1] == .invalidate_graphics_placements);
    try std.testing.expect(capture.events[2] == .offer_pane_geometry);
}

test "attachment dismissal can discover its layout change while applying the intent" {
    var capture: ViewInteractionCapture = .{};
    var handler: DispatchViewInteractionHandler = .{ .effects = capture.effects() };
    const id: types.Id = @enumFromInt(4);

    _ = try handler.execute(.{ .intent = .{ .attachment_dismiss = id } });

    try std.testing.expectEqual(@as(usize, 3), capture.count);
    try std.testing.expectEqualDeep(Intent{ .attachment_dismiss = id }, capture.events[0].intent);
    try std.testing.expect(capture.events[1] == .invalidate_graphics_placements);
    try std.testing.expect(capture.events[2] == .offer_pane_geometry);
}

test "DispatchViewInteractionHandler preserves completed stages across failures" {
    var capture: ViewInteractionCapture = .{ .failure = .intent };
    var handler: DispatchViewInteractionHandler = .{ .effects = capture.effects() };
    const command: ViewInteractionCommand = .{
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
    var capture: ViewInteractionCapture = .{};
    var handler: DispatchViewInteractionHandler = .{ .effects = capture.effects() };

    const outcome = try handler.execute(.{ .layout_changed = true, .consumed = true });

    try std.testing.expect(outcome.consume_pane_input);
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expect(capture.events[0] == .invalidate_graphics_placements);
    try std.testing.expect(capture.events[1] == .offer_pane_geometry);
}

test "DispatchViewInteractionHandler owns pane-input capture policy" {
    const cases = [_]struct {
        command: ViewInteractionCommand,
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
        var capture: ViewInteractionCapture = .{};
        var handler: DispatchViewInteractionHandler = .{ .effects = capture.effects() };

        const outcome = try handler.execute(case.command);

        try std.testing.expectEqual(case.consume, outcome.consume_pane_input);
    }
}
