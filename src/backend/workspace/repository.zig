//! In-memory repository for workspace aggregates.

const std = @import("std");
const core = @import("telar-core");
const state_mod = @import("state.zig");
const workspace_mod = @import("workspace.zig");

const schema = core.schema;
const State = state_mod.State;
const Workspace = workspace_mod.Workspace;

pub const Ensured = struct {
    location: schema.TabLocation,
    created: bool,
};

pub const Insert = struct {
    path: []const u8,
    explicit_name: ?[]const u8 = null,
};

pub const DescriptorSnapshot = struct {
    name: []const u8,
    tabs: []schema.TabDescriptor,
};

/// Repository-owned aggregate candidate that remains invisible until commit.
pub const Proposal = struct {
    repository: *Repository,
    workspace: ?Workspace,
    proposed_location: schema.TabLocation,

    /// Returns the stable identity reserved by this proposal.
    ///
    /// ```zig
    /// const location = proposal.location();
    /// ```
    pub fn location(proposal: *const Proposal) schema.TabLocation {
        std.debug.assert(proposal.workspace != null);
        return proposal.proposed_location;
    }

    /// Returns the proposal-owned workspace path until commit or rollback.
    ///
    /// ```zig
    /// const path = proposal.path();
    /// ```
    pub fn path(proposal: *const Proposal) []const u8 {
        return proposal.workspace.?.pathSlice();
    }

    /// Returns the canonical proposal-owned workspace name.
    ///
    /// ```zig
    /// const name = proposal.name();
    /// ```
    pub fn name(proposal: *const Proposal) []const u8 {
        return proposal.workspace.?.name();
    }

    /// Transfers the aggregate into repository state and advances identities
    /// and list revision exactly once.
    ///
    /// ```zig
    /// const location = proposal.commit();
    /// ```
    pub fn commit(proposal: *Proposal) schema.TabLocation {
        const repository = proposal.repository;
        std.debug.assert(proposal.workspace != null);
        std.debug.assert(schema.id.raw(workspaceId(proposal.proposed_location.workspace).?) == repository.state.next_workspace_id);
        std.debug.assert(schema.id.raw(proposal.proposed_location.tab_id) == repository.state.next_tab_id);
        std.debug.assert(repository.state.count < repository.state.items.len);

        for (&repository.state.items) |*slot| {
            if (slot.* != null) {
                continue;
            }

            slot.* = proposal.workspace.?;
            proposal.workspace = null;
            repository.state.count += 1;
            repository.state.next_workspace_id += 1;
            repository.state.next_tab_id += 1;
            state_mod.advanceRevision(repository.state);
            return proposal.proposed_location;
        }

        unreachable;
    }

    /// Releases an uncommitted aggregate. Calling it after commit is a no-op,
    /// which makes it safe in a transaction defer.
    ///
    /// ```zig
    /// defer proposal.rollback();
    /// ```
    pub fn rollback(proposal: *Proposal) void {
        const workspace = if (proposal.workspace) |*value| value else return;
        workspace.deinit(proposal.repository.gpa);
        proposal.workspace = null;
    }
};

pub const Reader = struct {
    state: *const State,

    pub fn init(state: *const State) Reader {
        return .{ .state = state };
    }

    pub fn count(reader: Reader) usize {
        return reader.state.count;
    }

    pub fn revision(reader: Reader) u64 {
        return reader.state.revision;
    }

    pub fn containsWorkspace(reader: Reader, location: schema.WorkspaceLocation) bool {
        return reader.find(location) != null;
    }

    /// Returns the default tab location for the first aggregate with `path`.
    ///
    /// ```zig
    /// const location = reader.locationByPath("/work/telar") orelse return;
    /// ```
    pub fn locationByPath(reader: Reader, path: []const u8) ?schema.TabLocation {
        const workspace = reader.findByPath(path) orelse return null;
        return .{
            .workspace = .{ .workspace = workspace.id },
            .tab_id = workspace.defaultTab(),
        };
    }

    fn find(reader: Reader, location: schema.WorkspaceLocation) ?*const Workspace {
        const workspace_id = workspaceId(location) orelse return null;

        for (&reader.state.items) |*slot| {
            const workspace = if (slot.*) |*value| value else continue;

            if (workspace.id == workspace_id) {
                return workspace;
            }
        }

        return null;
    }

    fn findByPath(reader: Reader, path: []const u8) ?*const Workspace {
        for (&reader.state.items) |*slot| {
            const workspace = if (slot.*) |*value| value else continue;

            if (std.mem.eql(u8, workspace.pathSlice(), path)) {
                return workspace;
            }
        }

        return null;
    }

    pub fn contains(reader: Reader, location: schema.TabLocation) bool {
        const workspace = reader.find(location.workspace) orelse return false;
        return workspace.containsTab(location.tab_id);
    }

    pub fn defaultTab(reader: Reader, location: schema.WorkspaceLocation) ?schema.TabId {
        const workspace = reader.find(location) orelse return null;
        return workspace.defaultTab();
    }

    pub fn workspacePath(reader: Reader, location: schema.WorkspaceLocation) ?[]const u8 {
        const workspace = reader.find(location) orelse return null;
        return workspace.pathSlice();
    }

    pub fn workspaceName(reader: Reader, location: schema.WorkspaceLocation) ?[]const u8 {
        const workspace = reader.find(location) orelse return null;
        return workspace.name();
    }

    /// The user-chosen workspace name, or null when the name derives from
    /// the path.
    ///
    /// ```zig
    /// const explicit = reader.explicitName(location) orelse "";
    /// ```
    pub fn explicitName(reader: Reader, location: schema.WorkspaceLocation) ?[]const u8 {
        const workspace = reader.find(location) orelse return null;
        return workspace.explicitName();
    }

    pub fn tabLabel(reader: Reader, location: schema.TabLocation) ?[]const u8 {
        const workspace = reader.find(location.workspace) orelse return null;
        return workspace.tabLabel(location.tab_id);
    }

    /// Returns the preceding aggregate in list order, wrapping at the start.
    ///
    /// ```zig
    /// const previous = reader.previousWorkspace(workspace_id);
    /// ```
    pub fn previousWorkspace(reader: Reader, workspace_id: schema.WorkspaceId) ?schema.WorkspaceId {
        if (reader.state.count < 2) {
            return null;
        }

        var current_index: ?usize = null;

        for (&reader.state.items, 0..) |*slot, index| {
            const workspace = if (slot.*) |*value| value else continue;

            if (workspace.id == workspace_id) {
                current_index = index;
                break;
            }
        }

        const current = current_index orelse return null;

        for (1..reader.state.items.len) |offset| {
            const index = (current + reader.state.items.len - offset) % reader.state.items.len;
            const workspace = if (reader.state.items[index]) |*value| value else continue;
            return workspace.id;
        }

        return null;
    }

    pub fn totalTabs(reader: Reader) usize {
        var count_value: usize = 0;

        for (&reader.state.items) |*slot| {
            const workspace = if (slot.*) |*value| value else continue;
            count_value += workspace.tabCount();
        }

        return count_value;
    }

    /// Writes the workspace snapshot projection into caller-owned tab storage.
    /// Returned labels borrow aggregate storage until its next mutation.
    ///
    /// ```zig
    /// var tabs: [max_tabs_per_workspace]schema.TabDescriptor = undefined;
    /// const snapshot = reader.descriptors(location, &tabs) orelse return;
    /// ```
    pub fn descriptors(reader: Reader, location: schema.WorkspaceLocation, output: *[workspace_mod.max_tabs_per_workspace]schema.TabDescriptor) ?DescriptorSnapshot {
        const workspace = reader.find(location) orelse return null;

        return .{
            .name = workspace.name(),
            .tabs = workspace.writeDescriptors(output),
        };
    }

    /// Writes the stable workspace-list projection into caller-owned storage.
    /// Returned slices borrow aggregate data and remain valid until mutation.
    ///
    /// ```zig
    /// var entries: [max_workspaces]schema.WorkspaceListEntry = undefined;
    /// const list = reader.listEntries(&entries);
    /// ```
    pub fn listEntries(reader: Reader, output: *[state_mod.max_workspaces]schema.WorkspaceListEntry) []const schema.WorkspaceListEntry {
        var count_value: usize = 0;

        for (&reader.state.items) |*slot| {
            const workspace = if (slot.*) |*value| value else continue;
            output[count_value] = .{
                .workspace = workspace.id,
                .name = workspace.name(),
                .path = workspace.pathSlice(),
                .tab_count = @intCast(workspace.tabCount()),
                .branch = workspace.gitBranch(),
                .dirty = workspace.git_dirty,
            };
            count_value += 1;
        }

        return output[0..count_value];
    }
};

pub const Repository = struct {
    state: *State,
    gpa: std.mem.Allocator,

    pub fn init(state: *State, gpa: std.mem.Allocator) Repository {
        return .{ .state = state, .gpa = gpa };
    }

    pub fn reader(repository: *const Repository) Reader {
        return Reader.init(repository.state);
    }

    pub fn find(repository: *Repository, location: schema.WorkspaceLocation) ?*Workspace {
        const workspace_id = workspaceId(location) orelse return null;

        for (&repository.state.items) |*slot| {
            const workspace = if (slot.*) |*value| value else continue;

            if (workspace.id == workspace_id) {
                return workspace;
            }
        }

        return null;
    }

    /// Returns the existing workspace for `path`, or inserts a new aggregate
    /// with its default tab. The repository owns the copied path on success.
    ///
    /// ```zig
    /// const ensured = try repository.ensure("/work/telar");
    /// ```
    pub fn ensure(repository: *Repository, path: []const u8) !Ensured {
        if (repository.reader().locationByPath(path)) |location| {
            return .{
                .location = location,
                .created = false,
            };
        }

        return .{
            .location = try repository.insert(.{ .path = path }),
            .created = true,
        };
    }

    /// Inserts one distinct aggregate and transfers ownership of its path copy
    /// to the repository. Equal paths remain valid distinct identities.
    ///
    /// ```zig
    /// const location = try repository.insert(.{
    ///     .path = "/work/telar",
    ///     .explicit_name = "backend",
    /// });
    /// ```
    pub fn insert(repository: *Repository, request: Insert) !schema.TabLocation {
        var proposal = try repository.propose(request);
        defer proposal.rollback();
        return proposal.commit();
    }

    /// Allocates and validates a distinct aggregate without exposing it or
    /// consuming its identities. The caller must commit or roll it back.
    ///
    /// ```zig
    /// var proposal = try repository.propose(.{ .path = "/work/telar" });
    /// defer proposal.rollback();
    /// ```
    pub fn propose(repository: *Repository, request: Insert) !Proposal {
        if (repository.state.count == repository.state.items.len) {
            return error.WorkspaceLimitReached;
        }

        const workspace_id = try schema.id.workspace(repository.state.next_workspace_id);
        const tab_id = try schema.id.tab(repository.state.next_tab_id);
        const path = try repository.gpa.dupe(u8, request.path);
        errdefer repository.gpa.free(path);
        const workspace = try Workspace.init(.{
            .id = workspace_id,
            .path = path,
            .default_tab_id = tab_id,
            .explicit_name = request.explicit_name,
        });

        return .{
            .repository = repository,
            .workspace = workspace,
            .proposed_location = .{
                .workspace = .{ .workspace = workspace_id },
                .tab_id = tab_id,
            },
        };
    }

    pub const Restore = struct {
        id: schema.WorkspaceId,
        path: []const u8,
        explicit_name: ?[]const u8,
        first_tab_id: schema.TabId,
        first_tab_label: []const u8,
    };

    /// Rebuilds one aggregate from a checkpoint with its original identities
    /// and advances the id counters past them. Only valid before clients
    /// connect; a duplicate identity is a corrupt checkpoint.
    ///
    /// ```zig
    /// const location = try repository.restoreWorkspace(.{ .id = id, .path = "/work", .explicit_name = null, .first_tab_id = tab, .first_tab_label = "main" });
    /// ```
    pub fn restoreWorkspace(repository: *Repository, request: Restore) !schema.TabLocation {
        if (repository.state.count == repository.state.items.len) {
            return error.WorkspaceLimitReached;
        }
        if (request.id == .invalid or request.first_tab_id == .invalid) {
            return error.InvalidCheckpointIdentity;
        }
        if (repository.find(.{ .workspace = request.id }) != null) {
            return error.DuplicateWorkspaceIdentity;
        }

        const path = try repository.gpa.dupe(u8, request.path);
        errdefer repository.gpa.free(path);
        var workspace = try Workspace.init(.{
            .id = request.id,
            .path = path,
            .default_tab_id = request.first_tab_id,
            .explicit_name = request.explicit_name,
        });
        _ = try workspace.renameTab(request.first_tab_id, request.first_tab_label);

        for (&repository.state.items) |*slot| {
            if (slot.* != null) continue;
            slot.* = workspace;
            repository.state.count += 1;
            break;
        } else unreachable;

        repository.state.next_workspace_id = @max(repository.state.next_workspace_id, schema.id.raw(request.id) + 1);
        repository.state.next_tab_id = @max(repository.state.next_tab_id, schema.id.raw(request.first_tab_id) + 1);
        state_mod.advanceRevision(repository.state);
        return .{ .workspace = .{ .workspace = request.id }, .tab_id = request.first_tab_id };
    }

    /// Rebuilds one additional tab of a restored workspace.
    ///
    /// ```zig
    /// try repository.restoreTab(location.workspace, tab_id, "logs");
    /// ```
    pub fn restoreTab(repository: *Repository, workspace_location: schema.WorkspaceLocation, tab_id: schema.TabId, label: []const u8) !void {
        const workspace = repository.find(workspace_location) orelse return error.WorkspaceNotFound;
        if (workspace.containsTab(tab_id)) return error.DuplicateTabIdentity;
        _ = try workspace.createTab(tab_id, label);
        repository.state.next_tab_id = @max(repository.state.next_tab_id, schema.id.raw(tab_id) + 1);
        state_mod.advanceRevision(repository.state);
    }

    /// Removes one aggregate and releases its repository-owned path.
    ///
    /// ```zig
    /// _ = repository.remove(workspace_id);
    /// ```
    pub fn remove(repository: *Repository, workspace_id: schema.WorkspaceId) bool {
        for (&repository.state.items) |*slot| {
            const workspace = if (slot.*) |*value| value else continue;

            if (workspace.id != workspace_id) {
                continue;
            }

            workspace.deinit(repository.gpa);
            slot.* = null;
            repository.state.count -= 1;
            state_mod.advanceRevision(repository.state);
            return true;
        }

        return false;
    }

    pub fn nextTabId(repository: *const Repository) !schema.TabId {
        return schema.id.tab(repository.state.next_tab_id);
    }

    /// Commits a previously proposed tab identity after aggregate mutation.
    /// Failed commands therefore leave both identity and list revision intact.
    ///
    /// ```zig
    /// repository.recordTabCreated(tab_id);
    /// ```
    pub fn recordTabCreated(repository: *Repository, tab_id: schema.TabId) void {
        std.debug.assert(schema.id.raw(tab_id) == repository.state.next_tab_id);
        repository.state.next_tab_id += 1;
        state_mod.advanceRevision(repository.state);
    }

    pub fn recordListChange(repository: *Repository) void {
        state_mod.advanceRevision(repository.state);
    }

    pub fn deinit(repository: *Repository) void {
        for (&repository.state.items) |*slot| {
            if (slot.*) |*workspace| {
                workspace.deinit(repository.gpa);
            }

            slot.* = null;
        }

        repository.state.* = .{};
    }
};

fn workspaceId(location: schema.WorkspaceLocation) ?schema.WorkspaceId {
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
    try repository.restoreTab(location.workspace, @enumFromInt(11), "logs");

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
