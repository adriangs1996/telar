const RestoreType = @import("Restore.zig");
const StateType = @import("State.zig");
const std = @import("std");
const ProbeSchedule = @import("ProbeSchedule.zig");
const ProbeType = @import("Probe.zig");
const WorkspaceType = @import("Workspace.zig");
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const ObservationType = @import("Observation.zig");
const Reader = @import("Reader.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const repository_support = @import("repository_support.zig");
const Ensured = @import("Ensured.zig");
const Insert = @import("Insert.zig");
const TabLocationType = @import("telar-core").TabLocation;
const Proposal = @import("Proposal.zig");
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const raw_module = @import("telar-core").raw;
const state_mod = @import("state_support.zig");
const TabIdType = @import("telar-core").TabId;
const Repository = @This();

state: *StateType,
gpa: std.mem.Allocator,

/// Reserves the stalest due workspace and copies its path for the worker.
/// Example: `const probe = repository.reserveGitProbe(.{ .now_ms = now, .interval_ms = 5000 }) orelse return;`.
pub fn reserveGitProbe(repository: *Repository, request: ProbeSchedule) ?ProbeType {
    if (repository.state.git_probe != null) {
        return null;
    }

    var stalest: ?*WorkspaceType = null;
    for (&repository.state.items) |*slot| {
        const workspace = if (slot.*) |*value| value else continue;
        if (request.now_ms -| workspace.git_checked_at_ms < request.interval_ms) {
            continue;
        }

        if (stalest == null or workspace.git_checked_at_ms < stalest.?.git_checked_at_ms) {
            stalest = workspace;
        }
    }

    const workspace = stalest orelse return null;
    const path = workspace.pathSlice();
    var probe: ProbeType = .{ .workspace = workspace.id, .path_len = @intCast(path.len) };
    @memcpy(probe.path[0..path.len], path);
    repository.state.git_probe = workspace.id;
    return probe;
}

/// Cancels only the matching observation, including a removed workspace.
/// Example: `repository.cancelGitProbe(probe.workspace);`.
pub fn cancelGitProbe(repository: *Repository, workspace: WorkspaceIdType) void {
    if (repository.state.git_probe == workspace) {
        repository.state.git_probe = null;
    }
}

/// Retires the reservation and publishes a changed projection exactly once.
/// Example: `if (repository.completeGitProbe(observation)) pumpClients();`.
pub fn completeGitProbe(repository: *Repository, observation: ObservationType) bool {
    if (repository.state.git_probe != observation.workspace) {
        return false;
    }

    repository.cancelGitProbe(observation.workspace);
    const workspace = repository.find(.{ .workspace = observation.workspace }) orelse return false;
    if (!workspace.completeGitProbe(observation)) {
        return false;
    }

    repository.recordListChange();
    return true;
}

pub fn init(state: *StateType, gpa: std.mem.Allocator) Repository {
    return .{ .state = state, .gpa = gpa };
}

pub fn reader(repository: *const Repository) Reader {
    return Reader.init(repository.state);
}

pub fn find(repository: *Repository, location: WorkspaceLocationType) ?*WorkspaceType {
    const workspace_id = repository_support.workspaceId(location) orelse return null;

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
pub fn insert(repository: *Repository, request: Insert) !TabLocationType {
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

    const workspace_id = try workspace_module(repository.state.next_workspace_id);
    const tab_id = try tab_module(repository.state.next_tab_id);
    const path = try repository.gpa.dupe(u8, request.path);
    errdefer repository.gpa.free(path);
    const workspace = try WorkspaceType.init(.{
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

pub const Restore = @import("Restore.zig");

/// Rebuilds one aggregate from a checkpoint with its original identities
/// and advances the id counters past them. Only valid before clients
/// connect; a duplicate identity is a corrupt checkpoint.
///
/// ```zig
/// const location = try repository.restoreWorkspace(.{ .id = id, .path = "/work", .explicit_name = null, .first_tab_id = tab, .first_tab_label = "main" });
/// ```
pub fn restoreWorkspace(repository: *Repository, request: RestoreType) !TabLocationType {
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
    var workspace = try WorkspaceType.init(.{
        .id = request.id,
        .path = path,
        .default_tab_id = request.first_tab_id,
        .explicit_name = request.explicit_name,
    });
    _ = try workspace.renameTab(request.first_tab_id, request.first_tab_label);

    for (&repository.state.items) |*slot| {
        if (slot.* != null) {
            continue;
        }
        slot.* = workspace;
        repository.state.count += 1;
        break;
    } else unreachable;

    repository.state.next_workspace_id = @max(repository.state.next_workspace_id, raw_module(request.id) + 1);
    repository.state.next_tab_id = @max(repository.state.next_tab_id, raw_module(request.first_tab_id) + 1);
    state_mod.advanceRevision(repository.state);
    return .{ .workspace = .{ .workspace = request.id }, .tab_id = request.first_tab_id };
}

/// Rebuilds one additional tab of a restored workspace.
///
/// ```zig
/// try repository.restoreTab(.{ .workspace = workspace, .tab_id = tab_id }, "logs");
/// ```
pub fn restoreTab(repository: *Repository, location: TabLocationType, label: []const u8) !void {
    const workspace = repository.find(location.workspace) orelse return error.WorkspaceNotFound;
    if (workspace.containsTab(location.tab_id)) {
        return error.DuplicateTabIdentity;
    }
    _ = try workspace.createTab(location.tab_id, label);
    repository.state.next_tab_id = @max(repository.state.next_tab_id, raw_module(location.tab_id) + 1);
    state_mod.advanceRevision(repository.state);
}

/// Removes one aggregate and releases its repository-owned path.
///
/// ```zig
/// _ = repository.remove(workspace_id);
/// ```
pub fn remove(repository: *Repository, workspace_id: WorkspaceIdType) bool {
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

pub fn nextTabId(repository: *const Repository) !TabIdType {
    return tab_module(repository.state.next_tab_id);
}

/// Commits a previously proposed tab identity after aggregate mutation.
/// Failed commands therefore leave both identity and list revision intact.
///
/// ```zig
/// repository.recordTabCreated(tab_id);
/// ```
pub fn recordTabCreated(repository: *Repository, tab_id: TabIdType) void {
    std.debug.assert(raw_module(tab_id) == repository.state.next_tab_id);
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
