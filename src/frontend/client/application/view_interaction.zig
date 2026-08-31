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
    redraw: bool = false,
    layout_changed: bool = false,
    consumed: bool = false,
};

pub const Outcome = struct {
    redraw: bool,
    consume_pane_input: bool,
};

pub const Effects = struct {
    context: *anyopaque,
    apply_intent: *const fn (*anyopaque, Intent) anyerror!void,
    sync_layout: *const fn (*anyopaque) anyerror!void,
};

pub const DispatchViewInteractionHandler = struct {
    effects: Effects,

    /// Applies the single semantic intent before any layout synchronization,
    /// then returns only the routing decision needed by host input.
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
            try handler.effects.sync_layout(handler.effects.context);
        }

        return .{
            .redraw = command.redraw,
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
    sync_layout,
};

const Capture = struct {
    events: [2]Event = undefined,
    count: usize = 0,
    fail_at: ?usize = null,

    fn effects(capture: *Capture) Effects {
        return .{
            .context = capture,
            .apply_intent = applyIntent,
            .sync_layout = syncLayout,
        };
    }

    fn record(capture: *Capture, event: Event) !void {
        capture.events[capture.count] = event;
        capture.count += 1;

        if (capture.fail_at == capture.count) {
            return error.ViewInteractionEffectFailed;
        }
    }

    fn applyIntent(context: *anyopaque, intent: Intent) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));

        try capture.record(.{ .intent = intent });
    }

    fn syncLayout(context: *anyopaque) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));

        try capture.record(.sync_layout);
    }
};

test "DispatchViewInteractionHandler applies intent before layout synchronization" {
    const key: agents.AgentKey = .{
        .pane_id = @enumFromInt(3),
        .pane_generation = 7,
    };
    var capture: Capture = .{};
    var handler: DispatchViewInteractionHandler = .{ .effects = capture.effects() };

    const outcome = try handler.execute(.{
        .intent = .{ .focus_agent = key },
        .redraw = true,
        .layout_changed = true,
    });

    try std.testing.expectEqualDeep(Outcome{
        .redraw = true,
        .consume_pane_input = true,
    }, outcome);
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqualDeep(Intent{ .focus_agent = key }, capture.events[0].intent);
    try std.testing.expect(capture.events[1] == .sync_layout);
}

test "DispatchViewInteractionHandler stops subsequent effects after failure" {
    var capture: Capture = .{ .fail_at = 1 };
    var handler: DispatchViewInteractionHandler = .{ .effects = capture.effects() };
    const command: Command = .{
        .intent = .{ .rename_tab = @enumFromInt(4) },
        .layout_changed = true,
    };

    try std.testing.expectError(error.ViewInteractionEffectFailed, handler.execute(command));
    try std.testing.expectEqual(@as(usize, 1), capture.count);

    capture = .{ .fail_at = 2 };
    handler = .{ .effects = capture.effects() };
    try std.testing.expectError(error.ViewInteractionEffectFailed, handler.execute(command));
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expect(capture.events[1] == .sync_layout);
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
