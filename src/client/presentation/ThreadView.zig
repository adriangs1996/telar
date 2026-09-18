const PaneIdType = @import("telar-core").PaneId;
const AgentType = @import("../agents/Agent.zig");
const AgentSnapshotType = @import("../agents/AgentSnapshot.zig");
const MultiplexerModel = @import("../workspace/MultiplexerModel.zig");
/// The content a thread surface shows: the agent running in the pane and the
/// composer draft. Transcript items arrive once the runtime indexes them;
/// until then the header alone identifies the agent.
const ThreadView = @This();
const core = @import("telar-core");
const Pane = @import("../panes/Pane.zig");

pane_id: PaneIdType,
agent: ?*const AgentType,
composer: []const u8,
composer_images: ?*const core.AgentImages = null,
composer_field: ?*const Pane.ComposerField = null,
composer_revision: u64 = 0,
attachment_generation: u64 = 0,
kind: core.PaneKind = .terminal,
transcript: ?*const core.AgentThreadSnapshot = null,
history: ?*const @import("../panes/AgentHistoryWindow.zig") = null,
history_generation: u64 = 0,
transcript_scroll: u32 = 0,
transcript_anchor_revision: u64 = 0,
focused: bool = false,
options: core.AgentOptions = .{},
options_revision: u64 = 0,
catalog_revision: u64 = 0,
cwd: []const u8 = "",
branch: []const u8 = "",

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

    return .{
        .pane_id = pane_id,
        .agent = agent,
        .composer = pane.composerSlice(),
        .composer_images = pane.composerImages(),
        .composer_field = pane.composer_field,
        .composer_revision = pane.composer_revision,
        .attachment_generation = pane.attachment_generation,
        .kind = pane.kind,
        .transcript = pane.agent_thread,
        .history = pane.agent_history,
        .history_generation = pane.history_generation,
        .transcript_scroll = pane.transcript_scroll,
        .transcript_anchor_revision = pane.transcript_anchor_revision,
        .focused = model.layout.focused() == pane_id,
        .options = pane.agentOptions(),
        .options_revision = pane.options_revision,
        .catalog_revision = pane.catalog_revision,
        .cwd = pane.cwdSlice(),
    };
}
