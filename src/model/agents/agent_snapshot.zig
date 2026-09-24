//! The runtime agent snapshot, reconciled into the client replica.

const AgentsSnapshotInput = @import("SnapshotInput.zig");
const std = @import("std");
const model_data = @import("../model.zig");
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");

/// Reconciles one newer runtime agent snapshot and records only status
/// transitions for identities already present in the previous revision.
///
/// ```zig
/// const commit = try agent_snapshot.reconcile(model, input) orelse return;
/// ```
pub fn reconcile(model: *ClientModel, input: AgentsSnapshotInput) !?model_data.AgentSnapshotCommit {
    if (input.revision <= model.agent_snapshot.revision) {
        return null;
    }
    if (input.agents.len > core.max_agent_snapshot_entries) {
        return error.TooManyAgents;
    }

    var status_changes: model_data.AgentStatusChanges = .{};
    for (input.agents) |agent| {
        const previous = model.agent_snapshot.find(agent.key) orelse continue;
        if (previous.status == agent.status) {
            continue;
        }

        status_changes.append(.{
            .key = agent.key,
            .pane_index = agent.pane_index,
            .provider = agent.provider,
            .previous = previous.status,
            .current = agent.status,
        });
    }

    const agent_revision_before = model.agent_revision;
    const replaced = try model.agent_snapshot.replace(input);
    std.debug.assert(replaced);
    model.agent_revision +%= 1;

    return .{
        .runtime_revision = model.agent_snapshot.revision,
        .count = model.agent_snapshot.count,
        .status_changes = status_changes,
        .agent_revision_before = agent_revision_before,
        .agent_revision = model.agent_revision,
    };
}
