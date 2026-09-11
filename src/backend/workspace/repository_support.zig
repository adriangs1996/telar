//! In-memory repository for workspace aggregates.

const std = @import("std");
const core = @import("telar-core");
const state_mod = @import("state_support.zig");
const workspace_mod = @import("workspace_support.zig");
const git = @import("git_observation.zig");
const ProbeSchedule = @import("ProbeSchedule.zig");

pub const schema = core.schema;
pub const State = state_mod.State;
pub const Workspace = workspace_mod.Workspace;

test "Git probes reserve one workspace, reject stale results and recover after removal" {
    var state: State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();
    const first = try repository.insert(.{ .path = "/first" });
    _ = try repository.insert(.{ .path = "/second" });
    const due: ProbeSchedule = .{ .now_ms = 5000, .interval_ms = 5000 };
    const probe = repository.reserveGitProbe(due).?;
    try std.testing.expectEqualStrings("/first", probe.pathSlice());
    try std.testing.expect(repository.reserveGitProbe(due) == null);
    repository.cancelGitProbe(@enumFromInt(999));
    try std.testing.expect(repository.reserveGitProbe(due) == null);
    repository.cancelGitProbe(probe.workspace);
    _ = repository.reserveGitProbe(due).?;
    const observation: git.Observation = .{ .workspace = probe.workspace, .branch = "main", .dirty = true, .checked_at_ms = 5000 };
    try std.testing.expect(repository.completeGitProbe(observation));
    const revision = repository.reader().revision();
    try std.testing.expect(!repository.completeGitProbe(observation));
    try std.testing.expectEqual(revision, repository.reader().revision());

    const second = repository.reserveGitProbe(due).?;
    try std.testing.expectEqualStrings("/second", second.pathSlice());
    try std.testing.expect(repository.remove(second.workspace));
    try std.testing.expect(!repository.completeGitProbe(.{ .workspace = second.workspace, .branch = "main", .dirty = false, .checked_at_ms = 5000 }));
    try std.testing.expect(repository.reserveGitProbe(due) == null);
    try std.testing.expectEqual(first.workspace.workspace, repository.reserveGitProbe(.{ .now_ms = 10000, .interval_ms = 5000 }).?.workspace);
    repository.cancelGitProbe(probe.workspace);
}

pub const Ensured = @import("Ensured.zig");

pub const Insert = @import("Insert.zig");

pub const DescriptorSnapshot = @import("DescriptorSnapshot.zig");

pub const Proposal = @import("Proposal.zig");

pub const Reader = @import("Reader.zig");

pub const Repository = @import("Repository.zig");

pub fn workspaceId(location: schema.WorkspaceLocation) ?schema.WorkspaceId {
    return switch (location) {
        .workspace => |id| id,
        .worktree => null,
    };
}

test "repository ensures stable path identity and owns aggregate storage" {
    var state: State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();

    const first = try repository.ensure("/work/project");
    const same = try repository.ensure("/work/project");
    const other = try repository.ensure("/work/other");
    const reader_value = repository.reader();

    try std.testing.expect(first.created);
    try std.testing.expect(!same.created);
    try std.testing.expect(other.created);
    try std.testing.expectEqualDeep(first.location, same.location);
    try std.testing.expect(!std.meta.eql(first.location, other.location));
    try std.testing.expect(reader_value.contains(first.location));
    try std.testing.expectEqualDeep(first.location, reader_value.locationByPath("/work/project").?);
    try std.testing.expect(reader_value.locationByPath("/work/missing") == null);

    var unknown_tab = first.location;
    unknown_tab.tab_id = try schema.id.tab(999);
    try std.testing.expect(!reader_value.contains(unknown_tab));
    try std.testing.expectEqual(@as(usize, 2), reader_value.count());
}

test "workspace proposals stay invisible and preserve identities on rollback" {
    var state: State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();
    const initial_revision = repository.reader().revision();
    var proposal = try repository.propose(.{
        .path = "/work/project",
        .explicit_name = "backend",
    });

    try std.testing.expectEqual(@as(usize, 0), repository.reader().count());
    try std.testing.expect(!repository.reader().contains(proposal.location()));
    try std.testing.expectEqual(initial_revision, repository.reader().revision());
    try std.testing.expectEqualStrings("/work/project", proposal.path());
    try std.testing.expectEqualStrings("backend", proposal.name());

    proposal.rollback();
    proposal.rollback();

    const inserted = try repository.insert(.{ .path = "/work/reused" });
    const workspace_id = workspaceId(inserted.workspace).?;
    try std.testing.expectEqual(@as(u64, 1), schema.id.raw(workspace_id));
    try std.testing.expectEqual(@as(u64, 1), schema.id.raw(inserted.tab_id));
}

test "committing a workspace proposal advances state exactly once" {
    var state: State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();
    const initial_revision = repository.reader().revision();
    var proposal = try repository.propose(.{ .path = "/work/project" });
    const proposed_location = proposal.location();

    const committed_location = proposal.commit();
    proposal.rollback();

    try std.testing.expectEqualDeep(proposed_location, committed_location);
    try std.testing.expect(repository.reader().contains(committed_location));
    try std.testing.expectEqual(@as(usize, 1), repository.reader().count());
    try std.testing.expect(repository.reader().revision() != initial_revision);
    try std.testing.expectEqual(@as(u64, 2), schema.id.raw(try repository.nextTabId()));
}

test "repository permits distinct aggregates with the same path" {
    var state: State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();

    const first = try repository.insert(.{
        .path = "/work/project",
        .explicit_name = "frontend",
    });
    const second = try repository.insert(.{
        .path = "/work/project",
        .explicit_name = "backend",
    });
    const reader_value = repository.reader();

    try std.testing.expect(!std.meta.eql(first, second));
    try std.testing.expectEqualStrings("frontend", reader_value.workspaceName(first.workspace).?);
    try std.testing.expectEqualStrings("backend", reader_value.workspaceName(second.workspace).?);
    try std.testing.expectEqualStrings(
        reader_value.workspacePath(first.workspace).?,
        reader_value.workspacePath(second.workspace).?,
    );
}

test "repository removal selects stable predecessors and releases storage" {
    var state: State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();

    const first = try repository.insert(.{ .path = "/work/first" });
    const second = try repository.insert(.{ .path = "/work/second" });
    const third = try repository.insert(.{ .path = "/work/third" });
    const first_id = workspaceId(first.workspace).?;
    const second_id = workspaceId(second.workspace).?;
    const third_id = workspaceId(third.workspace).?;

    try std.testing.expectEqual(first_id, repository.reader().previousWorkspace(second_id).?);
    try std.testing.expect(repository.remove(second_id));
    try std.testing.expectEqual(third_id, repository.reader().previousWorkspace(first_id).?);
    try std.testing.expect(!repository.remove(second_id));
}

test "reader creates bounded list and tab projections" {
    var state: State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();
    const location = try repository.insert(.{
        .path = "/work/project",
        .explicit_name = "agents",
    });
    const reader_value = repository.reader();

    var entries: [state_mod.max_workspaces]schema.WorkspaceListEntry = undefined;
    const list = reader_value.listEntries(&entries);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("agents", list[0].name);
    try std.testing.expectEqualStrings("/work/project", list[0].path);

    var descriptors: [workspace_mod.max_tabs_per_workspace]schema.TabDescriptor = undefined;
    const snapshot = reader_value.descriptors(location.workspace, &descriptors).?;
    try std.testing.expectEqualStrings("agents", snapshot.name);
    try std.testing.expectEqual(@as(usize, 1), snapshot.tabs.len);
    try std.testing.expectEqualStrings("main", snapshot.tabs[0].label);
}

test "failed insertion preserves repository identities and revision" {
    var state: State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();
    const initial_revision = repository.reader().revision();
    const oversized_name: [schema.max_tab_label_bytes + 1]u8 = @splat('x');

    try std.testing.expectError(error.InvalidWorkspaceName, repository.insert(.{
        .path = "/work/rejected",
        .explicit_name = &oversized_name,
    }));
    try std.testing.expectEqual(@as(usize, 0), repository.reader().count());
    try std.testing.expectEqual(initial_revision, repository.reader().revision());

    const inserted = try repository.insert(.{ .path = "/work/accepted" });
    const workspace_id = workspaceId(inserted.workspace).?;
    try std.testing.expectEqual(@as(u64, 1), schema.id.raw(workspace_id));
    try std.testing.expectEqual(@as(u64, 1), schema.id.raw(inserted.tab_id));
}

test "repository rejects aggregates beyond its fixed capacity" {
    var state: State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();

    for (0..state_mod.max_workspaces) |_| {
        _ = try repository.insert(.{ .path = "/work/project" });
    }

    const full_revision = repository.reader().revision();
    try std.testing.expectError(
        error.WorkspaceLimitReached,
        repository.insert(.{ .path = "/work/overflow" }),
    );
    try std.testing.expectEqual(state_mod.max_workspaces, repository.reader().count());
    try std.testing.expectEqual(full_revision, repository.reader().revision());
}

test "restored workspaces keep their identities and push the counters past them" {
    var state: State = .{};
    var repository = Repository.init(&state, std.testing.allocator);
    defer repository.deinit();

    const location = try repository.restoreWorkspace(.{
        .id = @enumFromInt(4),
        .path = "/work/telar",
        .explicit_name = "core",
        .first_tab_id = @enumFromInt(9),
        .first_tab_label = "editor",
    });
    try repository.restoreTab(.{ .workspace = location.workspace, .tab_id = @enumFromInt(11) }, "logs");

    try std.testing.expectEqual(@as(u64, 4), schema.id.raw(location.workspace.workspace));
    try std.testing.expectEqualStrings("core", repository.reader().workspaceName(location.workspace).?);
    try std.testing.expectEqualStrings("editor", repository.reader().tabLabel(location).?);
    try std.testing.expectEqualStrings("logs", repository.reader().tabLabel(.{ .workspace = location.workspace, .tab_id = @enumFromInt(11) }).?);
    try std.testing.expectEqual(@as(u64, 5), state.next_workspace_id);
    try std.testing.expectEqual(@as(u64, 12), state.next_tab_id);
    try std.testing.expectError(error.DuplicateWorkspaceIdentity, repository.restoreWorkspace(.{
        .id = @enumFromInt(4),
        .path = "/elsewhere",
        .explicit_name = null,
        .first_tab_id = @enumFromInt(20),
        .first_tab_label = "main",
    }));

    const fresh = try repository.ensure("/work/other");
    try std.testing.expectEqual(@as(u64, 5), schema.id.raw(fresh.location.workspace.workspace));
    try std.testing.expectEqual(@as(u64, 12), schema.id.raw(fresh.location.tab_id));
}
