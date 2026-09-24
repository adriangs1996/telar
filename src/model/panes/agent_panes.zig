//! An agent pane in the client model: its thread, composer, images, options and the prompt it submits.

const std = @import("std");
const AgentPane = @import("Pane.zig");
const AgentPromptIntent = @import("../agents/AgentPromptIntent.zig");
const model_data = @import("../model.zig");
const core = @import("telar-core");
const agent_options = @import("agent_options.zig");
const ClientModel = @import("../state/ClientModel.zig");

/// Flips the focused pane between its terminal cells and its thread view and
/// reports the surface now shown. Absent or empty layouts leave every version
/// intact.
///
/// ```zig
/// const surface = agent_panes.toggleSurface(model) orelse return;
/// ```
pub fn toggleSurface(model: *ClientModel) ?core.PaneSurface {
    const slot = model.tabs.activeSlot() orelse return null;
    const layout = &model.tabs.layout[slot];
    const focused = layout.focused() orelse return null;
    if (model.panes.findInConst(model.tabs.location[slot].tab_id, focused)) |pane| {
        if (pane.kind == .agent) {
            return .thread;
        }
    }

    const next: core.PaneSurface = switch (layout.surface(focused)) {
        .terminal => .thread,
        .thread => .terminal,
    };
    if (!layout.setSurface(focused, next)) {
        return null;
    }

    model.panes_revision +%= 1;
    return next;
}

/// Copies canonical conversation state only for the current runtime pane.
/// Example: `_ = try agent_panes.applyThread(model, snapshot);`
pub fn applyThread(model: *ClientModel, snapshot: core.AgentThreadSnapshotView) !bool {
    const pane = model.panes.find(snapshot.pane_id) orelse return false;
    if (!try pane.applyAgentThread(snapshot)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Mutates the composer through its owning pane. Example: `_ = agent_panes.editComposer(model, id, .backspace);`
pub fn editComposer(model: *ClientModel, pane_id: core.PaneId, command: model_data.PromptCommand) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent or !pane.editComposer(command)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Adds an image through its attached draft owner. Example: `_ = try agent_panes.attachImage(model, id, path);`
pub fn attachImage(model: *ClientModel, pane_id: core.PaneId, path: []const u8) !bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent) {
        return false;
    }

    try pane.attachComposerImage(path);
    model.panes_revision +%= 1;
    return true;
}

/// Example: `_ = agent_panes.removeImage(model, id, removal);`
pub fn removeImage(model: *ClientModel, pane_id: core.PaneId, removal: AgentPane.ImageRemoval) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent or !pane.removeComposerImage(removal)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Clears only the submitted draft revision; later typing stays intact.
/// Example: `_ = agent_panes.acceptPrompt(model, pane_id, composer_revision);`
pub fn acceptPrompt(model: *ClientModel, pane_id: core.PaneId, revision: u64) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent or !pane.acceptComposer(revision)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Stores disposable transcript navigation independently of provider state.
/// Example: `_ = agent_panes.scrollThread(model, pane_id, 3);`
pub fn scrollThread(model: *ClientModel, pane_id: core.PaneId, delta: f64) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent or !pane.scrollConversation(delta)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Commits one provider-backed composer selection. Example: `_ = agent_panes.changeOption(model, id, .{ .access = .read_only });`
pub fn changeOption(model: *ClientModel, pane_id: core.PaneId, change: agent_options.Change) bool {
    const pane = model.panes.find(pane_id) orelse return false;
    if (!pane.attached or pane.kind != .agent or !pane.changeAgentOption(change)) {
        return false;
    }

    model.panes_revision +%= 1;
    return true;
}

/// Example: `_ = agent_panes.planPrompt(model, pane_id);`
pub fn planPrompt(model: *ClientModel, pane_id: core.PaneId) ?AgentPromptIntent {
    const pane = model.agentPane(pane_id) orelse return null;
    const thread = pane.agent_thread orelse return null;
    if (thread.status != .ready or (std.mem.trim(u8, pane.composerSlice(), " \t\r\n").len == 0 and pane.composerImages().count == 0)) {
        return null;
    }
    const options = pane.agentOptions();
    if (!thread.accepts(options)) {
        return null;
    }

    return .{
        .pane_id = pane_id,
        .pane_generation = pane.pane_generation,
        .attachment_generation = pane.attachment_generation,
        .composer_content_revision = pane.composer_content_revision,
        .location = pane.location,
        .text = pane.composerSlice(),
        .images = pane.composerImages().view(),
        .options = options,
    };
}

/// Example: `_ = agent_panes.completePrompt(model, operation);`
pub fn completePrompt(model: *ClientModel, operation: model_data.AgentOperation) bool {
    const pane = model.agentPane(operation.pane_id) orelse return false;
    if (pane.pane_generation != operation.pane_generation or pane.attachment_generation != operation.attachment_generation) {
        return false;
    }

    const revision = operation.composer_content_revision orelse return false;
    return acceptPrompt(model, operation.pane_id, revision);
}
