const Capture = @This();
const source_namespace = @import("agent_navigation.zig");
const HandoffGate = @import("HandoffGate.zig");
const NavigationEffects = @import("NavigationEffects.zig");
const client_model = @import("../../root.zig").model;
blocked: bool = false,
select_result: bool = true,
failure_at: ?usize = null,
events: [3]source_namespace.Event = undefined,
count: usize = 0,

pub fn gate(capture: *Capture) HandoffGate {
    return .{ .context = capture, .pending = pending };
}

pub fn port(capture: *Capture) NavigationEffects {
    return .{
        .context = capture,
        .select_tab = selectTab,
        .focus_pane = focusPane,
        .request_handoff = requestHandoff,
    };
}

fn record(capture: *Capture, event: source_namespace.Event) !void {
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

fn selectTab(context: *anyopaque, tab_id: source_namespace.schema.TabId) !bool {
    const capture: *Capture = @ptrCast(@alignCast(context));
    try capture.record(.{ .select_tab = tab_id });

    return capture.select_result;
}

fn focusPane(context: *anyopaque, pane_id: source_namespace.schema.PaneId) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));

    try capture.record(.{ .focus_pane = pane_id });
}

fn requestHandoff(context: *anyopaque, handoff: client_model.AgentHandoff) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));

    try capture.record(.{ .handoff = handoff });
}
