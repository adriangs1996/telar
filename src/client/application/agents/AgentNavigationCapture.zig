const agent_navigation = @import("agent_navigation.zig");
const HandoffGate = @import("HandoffGate.zig");
const NavigationEffects = @import("NavigationEffects.zig");
const TabIdType = @import("telar-core").TabId;
const PaneIdType = @import("telar-core").PaneId;
const AgentHandoffType = @import("../../model/AgentHandoff.zig");
const Capture = @This();

blocked: bool = false,
select_result: bool = true,
failure_at: ?usize = null,
events: [3]agent_navigation.Event = undefined,
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

fn record(capture: *Capture, event: agent_navigation.Event) !void {
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

fn selectTab(context: *anyopaque, tab_id: TabIdType) !bool {
    const capture: *Capture = @ptrCast(@alignCast(context));
    try capture.record(.{ .select_tab = tab_id });

    return capture.select_result;
}

fn focusPane(context: *anyopaque, pane_id: PaneIdType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));

    try capture.record(.{ .focus_pane = pane_id });
}

fn requestHandoff(context: *anyopaque, handoff: AgentHandoffType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));

    try capture.record(.{ .handoff = handoff });
}
