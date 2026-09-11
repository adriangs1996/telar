const Snapshot = @This();
const source_namespace = @import("workspace_list.zig");
const Entry = @import("Entry.zig");
const SnapshotInput = @import("SnapshotInput.zig");
revision: u64 = 0,
count: usize = 0,
entries: [source_namespace.max_entries]Entry = undefined,
path_pool: [source_namespace.path_pool_size]u8 = undefined,
pool_len: usize = 0,

/// Atomically stores one newer runtime snapshot in fixed memory.
///
/// ```zig
/// _ = try snapshot.replace(.{ .revision = 1, .entries = entries });
/// ```
pub fn replace(snapshot: *Snapshot, input: SnapshotInput) !bool {
    if (input.revision <= snapshot.revision) {
        return false;
    }
    if (input.entries.len > source_namespace.max_entries) {
        return error.TooManyWorkspaces;
    }

    var replacement: Snapshot = .{
        .revision = input.revision,
        .count = input.entries.len,
    };

    for (input.entries, 0..) |entry, index| {
        if (entry.path.len > source_namespace.schema.max_cwd_bytes) {
            return error.WorkspacePathTooLong;
        }
        if (replacement.pool_len + entry.path.len > source_namespace.path_pool_size) {
            return error.WorkspaceListTooLarge;
        }

        for (input.entries[0..index]) |previous| {
            if (previous.workspace == entry.workspace) {
                return error.DuplicateWorkspace;
            }
        }

        const name = source_namespace.truncateName(entry.name);
        var stored: Entry = .{
            .workspace = entry.workspace,
            .name = undefined,
            .name_len = @intCast(name.len),
            .path_offset = @intCast(replacement.pool_len),
            .path_len = @intCast(entry.path.len),
            .tab_count = entry.tab_count,
        };
        const branch = entry.branch[0..@min(entry.branch.len, stored.branch.len)];
        @memcpy(stored.branch[0..branch.len], branch);
        stored.branch_len = @intCast(branch.len);
        stored.dirty = entry.dirty;
        @memcpy(stored.name[0..name.len], name);
        @memcpy(replacement.path_pool[replacement.pool_len..][0..entry.path.len], entry.path);
        replacement.pool_len += entry.path.len;
        replacement.entries[index] = stored;
    }

    snapshot.* = replacement;
    return true;
}

/// Returns one git branch borrowed from the snapshot, empty when unknown.
///
/// ```zig
/// const branch = snapshot.branchAt(0);
/// ```
pub fn branchAt(snapshot: *const Snapshot, index: usize) []const u8 {
    const entry = &snapshot.entries[index];
    return entry.branch[0..entry.branch_len];
}

pub fn dirtyAt(snapshot: *const Snapshot, index: usize) bool {
    return snapshot.entries[index].dirty;
}

/// Returns one display name borrowed from the snapshot.
///
/// ```zig
/// const name = snapshot.nameAt(0);
/// ```
pub fn nameAt(snapshot: *const Snapshot, index: usize) []const u8 {
    const entry = &snapshot.entries[index];
    return entry.name[0..entry.name_len];
}

/// Returns one complete workspace path borrowed from the snapshot.
///
/// ```zig
/// const path = snapshot.pathAt(0);
/// ```
pub fn pathAt(snapshot: *const Snapshot, index: usize) []const u8 {
    const entry = &snapshot.entries[index];
    return snapshot.path_pool[entry.path_offset..][0..entry.path_len];
}

/// Returns the workspace identity at a known valid index.
///
/// ```zig
/// const workspace = snapshot.workspaceAt(0);
/// ```
pub fn workspaceAt(snapshot: *const Snapshot, index: usize) source_namespace.schema.WorkspaceId {
    return snapshot.entries[index].workspace;
}

/// Resolves a bounded zero-based navigation position.
///
/// ```zig
/// const workspace = snapshot.workspaceAtPosition(0) orelse return;
/// ```
pub fn workspaceAtPosition(snapshot: *const Snapshot, position: usize) ?source_namespace.schema.WorkspaceId {
    if (position >= snapshot.count) {
        return null;
    }

    return snapshot.workspaceAt(position);
}

/// Finds a runtime workspace identity without exposing entry storage.
///
/// ```zig
/// const index = snapshot.indexOf(workspace) orelse return;
/// ```
pub fn indexOf(snapshot: *const Snapshot, workspace: source_namespace.schema.WorkspaceId) ?usize {
    for (snapshot.entries[0..snapshot.count], 0..) |entry, index| {
        if (entry.workspace == workspace) {
            return index;
        }
    }

    return null;
}
