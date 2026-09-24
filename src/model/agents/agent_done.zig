//! Acknowledging an agent that finished while its pane was not focused.

const std = @import("std");
const model_data = @import("../model.zig");
const ClientModel = @import("../state/ClientModel.zig");

/// Returns the focused agent that finished unseen, once per completion,
/// so the client can acknowledge it. Focus and the snapshot decide; no
/// version advances.
///
/// ```zig
/// const key = agent_done.takeAcknowledgement(model) orelse return;
/// ```
pub fn takeAcknowledgement(model: *ClientModel) ?model_data.AgentKey {
    const slot = model.tabs.activeSlot() orelse return null;
    const pane_id = model.tabs.layout[slot].focused() orelse return null;
    const key = model.agent_snapshot.keyForPane(model.tabs.location[slot], pane_id) orelse return null;
    const agent = model.agent_snapshot.find(key).?;
    const already = if (model.acknowledged_agent) |acknowledged| std.meta.eql(acknowledged, key) else false;

    if (agent.status != .done) {
        if (already) {
            model.acknowledged_agent = null;
        }

        return null;
    }

    if (already) {
        return null;
    }

    model.acknowledged_agent = key;
    return key;
}
