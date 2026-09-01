//! Application use case for navigating to one committed agent identity.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../../agents/root.zig");
const client_model = @import("../../model.zig");

const schema = core.schema;

pub const Outcome = enum {
    ignored,
    focused,
    handoff_requested,
};

pub const HandoffGate = struct {
    context: *anyopaque,
    pending: *const fn (*anyopaque) bool,
};

pub const NavigationEffects = struct {
    context: *anyopaque,
    select_tab: *const fn (*anyopaque, schema.TabId) anyerror!bool,
    focus_pane: *const fn (*anyopaque, schema.PaneId) anyerror!void,
    request_handoff: *const fn (*anyopaque, client_model.AgentHandoff) anyerror!void,
};

pub const NavigateAgentHandler = struct {
    model: *const client_model.Model,
    handoffs: HandoffGate,
    effects: NavigationEffects,

    /// Resolves one exact agent identity into ordered local navigation or a
    /// runtime handoff. Stale and blocked identities have no effects.
    ///
    /// ```zig
    /// const outcome = try handler.execute(agent_key);
    /// ```
    pub fn execute(handler: *NavigateAgentHandler, key: agents.AgentKey) !Outcome {
        const plan = handler.model.planAgentNavigation(key) orelse return .ignored;

        return switch (plan) {
            .local => |local| local: {
                if (local.select_tab) |tab_id| {
                    if (!try handler.effects.select_tab(handler.effects.context, tab_id)) {
                        break :local .ignored;
                    }
                }

                try handler.effects.focus_pane(handler.effects.context, local.pane_id);
                break :local .focused;
            },
            .handoff => |handoff| handoff: {
                if (handler.handoffs.pending(handler.handoffs.context)) {
                    break :handoff .ignored;
                }

                try handler.effects.request_handoff(handler.effects.context, handoff);
                break :handoff .handoff_requested;
            },
        };
    }
};

const Event = union(enum) {
    select_tab: schema.TabId,
    focus_pane: schema.PaneId,
    handoff: client_model.AgentHandoff,
};

const Capture = struct {
    blocked: bool = false,
    select_result: bool = true,
    failure_at: ?usize = null,
    events: [3]Event = undefined,
    count: usize = 0,

    fn gate(capture: *Capture) HandoffGate {
        return .{ .context = capture, .pending = pending };
    }

    fn port(capture: *Capture) NavigationEffects {
        return .{
            .context = capture,
            .select_tab = selectTab,
            .focus_pane = focusPane,
            .request_handoff = requestHandoff,
        };
    }

    fn record(capture: *Capture, event: Event) !void {
        capture.events[capture.count] = event;
        capture.count += 1;

        if (capture.failure_at == capture.count) {
            return error.NavigationEffectFailed;
        }
    }

    fn pending(context: *anyopaque) bool {
        const capture: *Capture = @ptrCast(@alignCast(context));

        return capture.blocked;
    }

    fn selectTab(context: *anyopaque, tab_id: schema.TabId) !bool {
        const capture: *Capture = @ptrCast(@alignCast(context));
        try capture.record(.{ .select_tab = tab_id });

        return capture.select_result;
    }

    fn focusPane(context: *anyopaque, pane_id: schema.PaneId) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));

        try capture.record(.{ .focus_pane = pane_id });
    }

    fn requestHandoff(context: *anyopaque, handoff: client_model.AgentHandoff) !void {
        const capture: *Capture = @ptrCast(@alignCast(context));

        try capture.record(.{ .handoff = handoff });
    }
};

const TestingModel = struct {
    model: *client_model.Model,
    local_key: agents.AgentKey,
    remote_key: agents.AgentKey,
    second: schema.TabLocation,

    fn init() !TestingModel {
        const model = try std.testing.allocator.create(client_model.Model);
        errdefer std.testing.allocator.destroy(model);
        model.* = client_model.Model.init(std.testing.allocator, true);
        errdefer model.deinit();
        const first: schema.TabLocation = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        };
        const second: schema.TabLocation = .{
            .workspace = first.workspace,
            .tab_id = @enumFromInt(2),
        };
        const local_key: agents.AgentKey = .{
            .pane_id = @enumFromInt(2),
            .pane_generation = 1,
        };
        const remote_key: agents.AgentKey = .{
            .pane_id = @enumFromInt(9),
            .pane_generation = 3,
        };
        try model.workspace.bootstrap(@enumFromInt(1), first, .{ .cols = 20, .rows = 5 });
        _ = try model.workspace.addCreated(.{
            .location = second,
            .position = 1,
            .label = "logs",
            .root_pane_id = local_key.pane_id,
        }, .{ .cols = 20, .rows = 5 });
        try std.testing.expect(model.workspace.select(first.tab_id));
        _ = try model.reconcileAgentSnapshot(.{
            .revision = 1,
            .agents = &.{
                .{
                    .key = local_key,
                    .location = second,
                    .pane_index = 1,
                    .provider = .codex,
                    .status = .working,
                },
                .{
                    .key = remote_key,
                    .location = .{
                        .workspace = .{ .workspace = @enumFromInt(3) },
                        .tab_id = @enumFromInt(6),
                    },
                    .pane_index = 2,
                    .provider = .claude,
                    .status = .ready,
                },
            },
        });

        return .{
            .model = model,
            .local_key = local_key,
            .remote_key = remote_key,
            .second = second,
        };
    }

    fn deinit(testing: *TestingModel) void {
        testing.model.deinit();
        std.testing.allocator.destroy(testing.model);
    }
};

test "NavigateAgentHandler orders local tab selection before pane focus" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{};
    var handler: NavigateAgentHandler = .{
        .model = testing.model,
        .handoffs = capture.gate(),
        .effects = capture.port(),
    };
    const version = testing.model.version();

    try std.testing.expectEqual(Outcome.focused, try handler.execute(testing.local_key));

    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqual(testing.second.tab_id, capture.events[0].select_tab);
    try std.testing.expectEqual(testing.local_key.pane_id, capture.events[1].focus_pane);
    try std.testing.expectEqualDeep(version, testing.model.version());
}

test "NavigateAgentHandler gates handoffs and stale identities without effects" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{ .blocked = true };
    var handler: NavigateAgentHandler = .{
        .model = testing.model,
        .handoffs = capture.gate(),
        .effects = capture.port(),
    };

    try std.testing.expectEqual(Outcome.ignored, try handler.execute(testing.remote_key));
    try std.testing.expectEqual(Outcome.ignored, try handler.execute(.{
        .pane_id = testing.remote_key.pane_id,
        .pane_generation = testing.remote_key.pane_generation + 1,
    }));
    try std.testing.expectEqual(@as(usize, 0), capture.count);

    capture.blocked = false;
    try std.testing.expectEqual(Outcome.handoff_requested, try handler.execute(testing.remote_key));
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualDeep(client_model.AgentHandoff{
        .pane_id = testing.remote_key.pane_id,
        .fallback_workspace = @enumFromInt(3),
    }, capture.events[0].handoff);
}

test "NavigateAgentHandler stops or propagates failed navigation effects in order" {
    var testing = try TestingModel.init();
    defer testing.deinit();
    var capture: Capture = .{ .select_result = false };
    var handler: NavigateAgentHandler = .{
        .model = testing.model,
        .handoffs = capture.gate(),
        .effects = capture.port(),
    };

    try std.testing.expectEqual(Outcome.ignored, try handler.execute(testing.local_key));
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(capture.events[0] == .select_tab);

    capture.select_result = true;
    capture.failure_at = 1;
    capture.count = 0;
    try std.testing.expectError(error.NavigationEffectFailed, handler.execute(testing.local_key));
    try std.testing.expectEqual(@as(usize, 1), capture.count);

    capture.failure_at = 2;
    capture.count = 0;
    try std.testing.expectError(error.NavigationEffectFailed, handler.execute(testing.local_key));
    try std.testing.expectEqual(@as(usize, 2), capture.count);

    capture.failure_at = 1;
    capture.count = 0;
    try std.testing.expectError(error.NavigationEffectFailed, handler.execute(testing.remote_key));
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expect(capture.events[0] == .handoff);
}
