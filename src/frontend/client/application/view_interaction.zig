//! Application policy for dispatching one semantic view interaction.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../agents/root.zig");
const notification_capability = @import("../../notifications/root.zig");

const schema = core.schema;

pub const Intent = union(enum) {
    none,
    toggle_sidebar,
    toggle_workspace_list,
    focus_agent: agents.AgentKey,
    select_tab: schema.TabId,
    focus_pane: schema.PaneId,
    rename_tab: schema.TabId,
    select_workspace: schema.WorkspaceId,
    notification_activate: notification_capability.Id,
    notification_dismiss: notification_capability.Id,
};

pub const Command = struct {
    intent: Intent = .none,
    layout_changed: bool = false,
    consumed: bool = false,
};

pub const Outcome = struct {
    consume_pane_input: bool,
};

pub const Effects = struct {
    context: *anyopaque,
    apply_intent: *const fn (*anyopaque, Intent) anyerror!void,
    invalidate_graphics_placements: *const fn (*anyopaque) void,
    offer_pane_geometry: *const fn (*anyopaque) anyerror!void,
};

pub const DispatchViewInteractionHandler = struct {
    effects: Effects,

    /// Applies the single semantic intent before ordered layout delivery, then
    /// returns only the routing decision needed by host input.
    ///
    /// ```zig
    /// const outcome = try handler.execute(command);
    /// ```
    pub fn execute(handler: *DispatchViewInteractionHandler, command: Command) !Outcome {
        switch (command.intent) {
            .none => {},
            else => try handler.effects.apply_intent(handler.effects.context, command.intent),
        }

        if (command.layout_changed) {
            handler.effects.invalidate_graphics_placements(handler.effects.context);
            try handler.effects.offer_pane_geometry(handler.effects.context);
        }

        return .{
            .consume_pane_input = command.consumed or capturesPaneInput(command.intent),
        };
    }
};

fn capturesPaneInput(intent: Intent) bool {
    return switch (intent) {
        .select_tab, .focus_agent => true,
        else => false,
    };
}

const Event = union(enum) {
    intent: Intent,
    invalidate_graphics_placements,
    offer_pane_geometry,
};

const Failure = enum {
    none,
    intent,
    pane_geometry,
};

const Capture = struct {
    events: [3]Event = undefined,
    count: usize = 0,
    failure: Failure = .none,

    fn effects(capture: *Capture) Effects {
        return .{
            .context = capture,
            .apply_intent = applyIntent,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .offer_pane_geometry = offerPaneGeometry,
        };
    }

    fn record(capture: *Capture, event: Event) void {
        capture.events[capture.count] = event;
        capture.count += 1;
    }

    fn applyIntent(context: *anyopaque, intent: Intent) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.record(.{ .intent = intent });

        if (capture.failure == .intent) {
            return error.ViewIntentFailed;
        }
    }

    fn invalidateGraphicsPlacements(context: *anyopaque) void {
        const capture: *Capture = @ptrCast(@alignCast(context));

        capture.record(.invalidate_graphics_placements);
    }

    fn offerPaneGeometry(context: *anyopaque) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));
        capture.record(.offer_pane_geometry);

        if (capture.failure == .pane_geometry) {
            return error.PaneGeometryFailed;
        }
    }
};

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
