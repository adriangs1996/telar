const PaneIdType = @import("telar-core").PaneId;
const AgentType = @import("../agents/Agent.zig");
const AgentSnapshotType = @import("../agents/AgentSnapshot.zig");
const MultiplexerModel = @import("../workspace/MultiplexerModel.zig");
/// The content a thread surface shows: the agent running in the pane and the
/// composer draft. Transcript items arrive once the runtime indexes them;
/// until then the header alone identifies the agent.
const ThreadView = @This();

pane_id: PaneIdType,
agent: ?*const AgentType,
composer: []const u8,

/// Borrows the thread view of one pane, or null when the model does not hold
/// that pane. The agent is null while no agent runs in the pane.
///
/// ```zig
/// const thread = ThreadView.capture(model, agents, pane_id) orelse return;
/// ```
pub fn capture(model: *const MultiplexerModel, agents: ?*const AgentSnapshotType, pane_id: PaneIdType) ?ThreadView {
    const pane = model.findConst(pane_id) orelse return null;
    const agent = if (agents) |snapshot| found: {
        const key = snapshot.keyForPane(pane.location, pane_id) orelse break :found null;
        break :found snapshot.find(key);
    } else null;

    return .{ .pane_id = pane_id, .agent = agent, .composer = pane.composerSlice() };
}
