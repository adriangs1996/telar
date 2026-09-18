const std = @import("std");
const core = @import("telar-core");
const Model = @import("../../model/Model.zig");
const Command = @import("../../model/name_prompt.zig").Command;
const AgentOperation = @import("../../connection/AgentOperation.zig");
const AgentPromptIntent = @import("AgentPromptIntent.zig");
const AgentThreadHandler = @This();

model: *Model,

/// Plans one complete prompt without clearing its draft. Example: `const intent = handler.prompt(pane_id) orelse return;`
pub fn prompt(handler: AgentThreadHandler, pane_id: core.PaneId) ?AgentPromptIntent {
    const pane = handler.model.agentPane(pane_id) orelse return null;
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

/// Example: `_ = try handler.attachImage(id, path);`
pub fn attachImage(handler: AgentThreadHandler, pane_id: core.PaneId, path: []const u8) !bool {
    return handler.model.attachAgentImage(pane_id, path);
}

/// Example: `_ = handler.removeImage(id, removal);`
pub fn removeImage(handler: AgentThreadHandler, pane_id: core.PaneId, removal: @import("../../panes/Pane.zig").ImageRemoval) bool {
    return handler.model.removeAgentImage(pane_id, removal);
}

/// Applies editor commands through the model owner. Example: `_ = handler.edit(pane_id, .backspace);`
pub fn edit(handler: AgentThreadHandler, pane_id: core.PaneId, command: Command) bool {
    return handler.model.editAgentComposer(pane_id, command);
}

/// Retains a validated runtime snapshot in the attached pane. Example: `_ = try handler.apply(snapshot);`
pub fn apply(handler: AgentThreadHandler, snapshot: core.AgentThreadSnapshotView) !bool {
    return handler.model.applyAgentThread(snapshot);
}

/// Acknowledges one submitted draft without consuming later edits or a replacement attachment.
/// Example: `_ = handler.complete(operation);`
pub fn complete(handler: AgentThreadHandler, operation: AgentOperation) bool {
    const pane = handler.model.agentPane(operation.pane_id) orelse return false;
    if (pane.pane_generation != operation.pane_generation or pane.attachment_generation != operation.attachment_generation) {
        return false;
    }

    const revision = operation.composer_content_revision orelse return false;
    return handler.model.acceptAgentPrompt(operation.pane_id, revision);
}

/// Updates client-owned transcript navigation. Example: `_ = handler.scroll(pane_id, 3);`
pub fn scroll(handler: AgentThreadHandler, pane_id: core.PaneId, delta: f64) bool {
    return handler.model.scrollAgentThread(pane_id, delta);
}

/// Admits the runtime identity only after attachment correlation. Example: `_ = handler.identify(opened);`
pub fn identify(handler: AgentThreadHandler, opened: core.PaneOpened) bool {
    return handler.model.identifyPane(opened);
}

/// Chooses settings only from the current runtime catalog. Example: `_ = handler.select(id, .{ .effort = effort });`
pub fn select(handler: AgentThreadHandler, pane_id: core.PaneId, change: @import("../../panes/agent_options.zig").Change) bool {
    return handler.model.changeAgentOption(pane_id, change);
}
