const ModelType = @import("../../model/Model.zig");
const HandoffGate = @import("HandoffGate.zig");
const NavigationEffects = @import("NavigationEffects.zig");
const AgentKeyType = @import("../../agents/AgentKey.zig");
const agent_navigation = @import("agent_navigation.zig");
const NavigateAgentHandler = @This();

model: *const ModelType,
handoffs: HandoffGate,
effects: NavigationEffects,

/// Resolves one exact agent identity into ordered local navigation or a
/// runtime handoff. Stale and blocked identities have no effects.
///
/// ```zig
/// const outcome = try handler.execute(agent_key);
/// ```
pub fn execute(handler: *NavigateAgentHandler, key: AgentKeyType) !agent_navigation.Outcome {
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
