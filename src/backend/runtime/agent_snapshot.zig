//! The agent snapshot clients show in their sidebar: tracker entries enriched
//! with each pane's tab, position, labels, cwd and title. Its revision
//! follows the agents, panes and workspaces it reads, and it is built at most
//! once per flush however many clients receive it.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const AgentDisplayStorage = @import("delivery/AgentDisplayStorage.zig");
const Sources = @import("delivery/Sources.zig");
const delivery_namespace = @import("delivery/delivery_namespace.zig");
const revisions = @import("../revisions.zig");

const max_entries = core.max_agent_snapshot_entries;

/// Advances the snapshot revision when an input it reads changed.
///
/// ```zig
/// agent_snapshot.refresh(model);
/// ```
pub fn refresh(model: *RuntimeModel) void {
    const inputs = [_]u64{
        model.agents.revision,
        model.panes.revision,
        model.workspaces.revision,
        model.workspaces.label_revision,
    };
    if (std.mem.eql(u64, &inputs, &model.agent_snapshot_inputs)) {
        return;
    }

    model.agent_snapshot_inputs = inputs;
    revisions.advance(&model.agent_snapshot_revision);
}

/// Reports whether some active client sends the snapshot in this flush.
///
/// ```zig
/// if (agent_snapshot.wanted(model)) sources.agent_entries = agent_snapshot.project(sources, &entries, &display);
/// ```
pub fn wanted(model: *RuntimeModel) bool {
    for (&model.clients.items) |*slot| {
        const session = slot.* orelse continue;
        const delivery = &session.delivery;
        if (!session.active()) {
            continue;
        }

        if (delivery.agent_snapshot_requested or (delivery.runtime_state_requested and delivery.agent_revision_sent < model.agent_snapshot_revision)) {
            return true;
        }
    }

    return false;
}

/// Builds the enriched entries into caller storage. Labels borrow panes,
/// workspaces and `display` until the next mutation.
///
/// ```zig
/// const entries = agent_snapshot.project(sources, &model.agent_entries, &model.agent_display);
/// ```
pub fn project(sources: Sources, entries: *[max_entries]core.AgentSnapshotEntry, display: *[max_entries]AgentDisplayStorage) []const core.AgentSnapshotEntry {
    const tracked = sources.agents.snapshot(entries, sources.now_ms);
    var count: usize = 0;
    for (tracked) |entry| {
        const pane = sources.panes.resolveConst(.{
            .id = entry.pane_id,
            .generation = entry.pane_generation,
        }) orelse continue;
        const pane_index = sources.panes.positionAt(pane) orelse continue;
        var enriched = entry;
        enriched.location = pane.location;
        enriched.pane_index = pane_index;

        if (entry.provider != .unknown) {
            enriched.provider_name = sources.manifests.providerName(entry.provider);
            enriched.display_name = sources.manifests.displayName(entry.provider);
            enriched.icon = sources.manifests.icon(entry.provider);
            enriched.attachments = sources.manifests.attachments(entry.provider);
        }

        if (sources.workspaces.workspaceName(pane.location.workspace)) |workspace_name| {
            enriched.workspace_label = delivery_namespace.copyDisplayPrefix(&display[count].workspace, workspace_name);
        }

        if (sources.workspaces.tabLabel(pane.location)) |tab_label| {
            enriched.tab_label = tab_label;
        }

        if (entry.title_source == .telar and pane.title.len != 0) {
            enriched.session_title = delivery_namespace.truncateUtf8(pane.title.slice(), core.max_agent_session_title_bytes);
            enriched.title_source = .terminal;
        } else if (entry.title_source == .telar) {
            enriched.session_title = sources.manifests.placeholderTitle(entry.provider, &display[count].placeholder);
        }

        enriched.cwd_label = delivery_namespace.shortenCwd(&display[count].cwd, pane.cwd.slice(), sources.home);
        entries[count] = enriched;
        count += 1;
    }

    return entries[0..count];
}

test "display context changes advance the snapshot revision once each" {
    const gpa = std.testing.allocator;
    const model = try gpa.create(RuntimeModel);
    defer gpa.destroy(model);
    model.agents = .{};
    model.panes = .{};
    model.workspaces = .{};
    defer model.workspaces.deinit(gpa);
    model.agent_snapshot_revision = 1;
    model.agent_snapshot_inputs = @splat(0);

    refresh(model);
    const initial = model.agent_snapshot_revision;
    refresh(model);
    try std.testing.expectEqual(initial, model.agent_snapshot_revision);

    const location = try model.workspaces.insert(gpa, "/work/telar", null);
    refresh(model);
    const created = model.agent_snapshot_revision;
    try std.testing.expect(created > initial);

    try model.workspaces.renameTab(location, "logs");
    refresh(model);
    const renamed = model.agent_snapshot_revision;
    try std.testing.expect(renamed > created);

    revisions.advance(&model.panes.revision);
    refresh(model);
    try std.testing.expect(model.agent_snapshot_revision > renamed);
}
