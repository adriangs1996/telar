const std = @import("std");
const AgentThreadHandler = @import("../../application/agents/AgentThreadHandler.zig");
const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const tab_creations = @import("../tabs/tab_creations.zig");

/// Applies one routed command within this domain. Example: `try agent_commands.execute(client, reply);`
pub fn execute(client: *Client, reply: *core.ClientCommand) !void {
    switch (reply.action) {
        .agent_view_expand, .agent_view_collapse => {
            _ = client.model.agentPane(@enumFromInt(reply.target_id)) orelse return error.AgentPaneNotAttached;
            const item_id = std.fmt.parseUnsigned(u64, reply.text(), 10) catch return error.InvalidItemId;
            if (item_id == 0 or (reply.value != 0 and reply.value != 1)) {
                return error.InvalidThreadControl;
            }

            try client.host_input_source.setThreadExpansion(.{ .pane_id = @enumFromInt(reply.target_id), .item_id = item_id, .expanded = reply.action == .agent_view_expand, .work = reply.value == 1 });
            reply.length = 0;
            reply.status = .applied;
        },
        .agent_draft_attach => {
            const pane_id: core.PaneId = @enumFromInt(reply.target_id);
            const pane = client.model.agentPane(pane_id) orelse return error.AgentPaneNotAttached;
            const handler: AgentThreadHandler = .{ .model = &client.model };
            if (!try handler.attachImage(pane_id, reply.text())) {
                return error.DraftAttachmentRejected;
            }

            reply.value = pane.composerImages().count;
            reply.length = 0;
            reply.status = .applied;
        },
        .agent_draft_set => {
            const pane_id: core.PaneId = @enumFromInt(reply.target_id);
            const pane = client.model.agentPane(pane_id) orelse return error.AgentPaneNotAttached;
            if (std.mem.indexOfScalar(u8, reply.text(), 0) != null) {
                return error.InvalidDraftText;
            }

            if (!std.mem.eql(u8, pane.composerSlice(), reply.text())) {
                const handler: AgentThreadHandler = .{ .model = &client.model };
                if (!handler.edit(pane_id, .{ .replace_range = .{ .range = .{ 0, @intCast(pane.composerSlice().len) }, .text = reply.text() } })) {
                    return error.DraftEditRejected;
                }
            }

            reply.length = 0;
            reply.status = .applied;
        },
        .agent_draft_get => {
            const pane_id: core.PaneId = @enumFromInt(reply.target_id);
            const pane = client.model.agentPane(pane_id) orelse return error.AgentPaneNotAttached;
            reply.value = pane.composerImages().count;
            try reply.setText(pane.composerSlice());
            reply.status = .applied;
        },
        .agent_create => {
            if (!client.model.hostCapabilities().agent_panes) {
                return error.AgentPanesUnsupported;
            }

            var handler = tab_creations.requestHandler(client);
            if (!try handler.execute(.{ .kind = .agent, .label = if (reply.length == 0) "Codex" else reply.text() })) {
                return error.ClientBusy;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        else => return error.InvalidClientCommand,
    }
}
