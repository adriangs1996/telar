const core = @import("telar-core");
const std = @import("std");
const Session = @import("Session.zig");
const PaneRef = @import("PaneRef.zig");
const ManagedAgent = @This();
const AgentPromptInput = @import("AgentPromptInput.zig");
const AgentHistoryInput = @import("AgentHistoryInput.zig");

session: *Session,
pane: PaneRef,

/// Interrupts exactly the resolved pane generation. Example: `try managed.interrupt();`
pub fn interrupt(self: *ManagedAgent) !void {
    const response = try self.session.exchange(core.encodeAgentInterrupt, core.AgentInterrupt{
        .request_id = .none,
        .pane_id = try core.pane(self.pane.pane_id),
        .pane_generation = self.pane.pane_generation,
    });
    if (response != .request_completed) {
        return error.UnexpectedRuntimeResponse;
    }
}

/// Copies one bounded, generation-checked conversation snapshot. Example: `try managed.read(snapshot);`
pub fn read(self: *ManagedAgent, snapshot: *core.AgentThreadSnapshot) !void {
    const pane_id = try core.pane(self.pane.pane_id);
    const accepted = try self.session.exchange(core.encodeQueryAgentThread, core.QueryAgentThread{
        .request_id = .none,
        .pane_id = pane_id,
        .pane_generation = self.pane.pane_generation,
    });
    if (accepted != .request_completed) {
        return error.UnexpectedRuntimeResponse;
    }

    while (true) {
        const response = try self.session.receive();
        if (response != .agent_thread_snapshot) {
            continue;
        }

        const view = response.agent_thread_snapshot;
        if (view.pane_id != pane_id or view.pane_generation != self.pane.pane_generation) {
            return error.UnexpectedRuntimeResponse;
        }

        try view.copyTo(snapshot);
        return;
    }
}

/// Answers one explicit approval, never an implicit current request. Example: `try managed.decide(.{ .id = 42, .accepted = true });`
pub fn decide(self: *ManagedAgent, decision: core.AgentApprovalDecision) !void {
    const response = try self.session.exchange(core.encodeAgentApproval, core.AgentApproval{
        .request_id = .none,
        .pane_id = try core.pane(self.pane.pane_id),
        .pane_generation = self.pane.pane_generation,
        .approval_id = decision.id,
        .accept = decision.accepted,
    });
    if (response != .request_completed) {
        return error.UnexpectedRuntimeResponse;
    }
}

/// Uses the live provider selection and waits for admission. Example: `try managed.prompt(.{ .text = "Run tests" });`
pub fn prompt(self: *ManagedAgent, input: AgentPromptInput) !void {
    const snapshot = try self.session.gpa.create(core.AgentThreadSnapshot);
    defer self.session.gpa.destroy(snapshot);
    try self.read(snapshot);
    var selection = snapshot.options;
    if (input.model) |model_id| {
        const model = snapshot.findModel(model_id) orelse return error.UnsupportedAgentModel;
        try selection.setModel(model_id);
        selection.effort = model.default_effort;
    }

    if (input.effort) |effort| {
        selection.effort = effort;
    }

    if (input.access) |access| {
        selection.access = access;
    }

    if (!snapshot.accepts(selection)) {
        return error.InvalidAgentOptions;
    }

    const response = try self.session.exchange(core.encodeAgentPrompt, core.AgentPrompt{
        .request_id = .none,
        .pane_id = try core.pane(self.pane.pane_id),
        .pane_generation = self.pane.pane_generation,
        .text = input.text,
        .images = input.images,
        .options = selection,
    });
    if (response != .request_completed) {
        return error.UnexpectedRuntimeResponse;
    }
}

/// Fetches one independent provider page. Example: `try managed.history(.{ .cursor = next }, page);`
pub fn history(self: *ManagedAgent, input: AgentHistoryInput, page: *core.AgentHistoryPage) !void {
    const initial_view_generation = 1;
    const response = try self.session.exchange(core.encodeQueryAgentHistory, core.QueryAgentHistory{
        .request_id = .none,
        .pane_id = try core.pane(self.pane.pane_id),
        .pane_generation = self.pane.pane_generation,
        .view_generation = initial_view_generation,
        .cursor = input.cursor,
        .anchor = input.anchor,
        .anchor_turn = input.anchor_turn,
        .direction = input.direction,
    });
    if (response != .agent_history_page) {
        return error.UnexpectedRuntimeResponse;
    }

    const view = response.agent_history_page;
    if (core.raw(view.snapshot.pane_id) != self.pane.pane_id or view.snapshot.pane_generation != self.pane.pane_generation or view.view_generation != initial_view_generation) {
        return error.UnexpectedRuntimeResponse;
    }

    try view.copyTo(page);
}

/// Resolves a stable conversation ID and pins the catalog revision. Example: `try managed.resumeConversation("thread-id");`
pub fn resumeConversation(self: *ManagedAgent, conversation_id: []const u8) !void {
    const snapshot = try self.session.gpa.create(core.AgentThreadSnapshot);
    defer self.session.gpa.destroy(snapshot);
    try self.read(snapshot);
    if (!snapshot.canResume() or snapshot.recent.phase != .ready) {
        return error.AgentCannotResume;
    }

    for (snapshot.recent.entries[0..snapshot.recent.count], 0..) |*entry, index| {
        if (!std.mem.eql(u8, entry.idSlice(), conversation_id)) {
            continue;
        }

        const response = try self.session.exchange(core.encodeAgentResume, core.AgentResume{
            .request_id = .none,
            .pane_id = try core.pane(self.pane.pane_id),
            .pane_generation = self.pane.pane_generation,
            .expected_revision = snapshot.revision,
            .conversation_index = @intCast(index),
        });
        if (response != .request_completed) {
            return error.UnexpectedRuntimeResponse;
        }

        return;
    }

    return error.ConversationNotFound;
}
