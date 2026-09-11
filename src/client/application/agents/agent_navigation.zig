//! Application use case for navigating to one committed agent identity.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../root.zig").agents;
const client_model = @import("../../root.zig").model;

pub const schema = core.schema;

pub const Outcome = enum {
    ignored,
    focused,
    handoff_requested,
};

pub const HandoffGate = @import("HandoffGate.zig");

pub const NavigationEffects = @import("NavigationEffects.zig");

pub const NavigateAgentHandler = @import("NavigateAgentHandler.zig");

pub const Event = union(enum) {
    select_tab: schema.TabId,
    focus_pane: schema.PaneId,
    handoff: client_model.AgentHandoff,
};

const Capture = @import("AgentNavigationCapture.zig");

const TestingModel = @import("TestingModel.zig");

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
