//! Bounded replica of the runtime's open-workspace list.
//!
//! The runtime owns workspace truth; the client keeps this disposable copy so
//! the top bar can list every open workspace and switch on click. Replacement
//! follows the sidebar snapshot contract: reject stale revisions, copy into
//! fixed storage, allocate nothing.

const std = @import("std");
const core = @import("telar-core");

const schema = core.schema;

pub const max_entries = schema.max_workspace_list_entries;
/// Display cap; a longer basename is truncated on a codepoint boundary.
pub const max_name_bytes = 48;
/// One shared pool for every stored path. Paths feed `open_pane` on switch,
/// so they are kept whole; a snapshot that cannot fit is rejected rather
/// than silently truncated into unswitchable entries.
pub const path_pool_size = 16 * 1024;

pub const EntryInput = struct {
    workspace: schema.WorkspaceId,
    name: []const u8,
    path: []const u8,
    tab_count: u16,
};

pub const SnapshotInput = struct {
    revision: u64,
    entries: []const EntryInput,
};

const Entry = struct {
    workspace: schema.WorkspaceId,
    name: [max_name_bytes]u8,
    name_len: u8,
    path_offset: u32,
    path_len: u32,
    tab_count: u16,
};

pub const Snapshot = struct {
    revision: u64 = 0,
    initialized: bool = false,
    count: usize = 0,
    entries: [max_entries]Entry = undefined,
    path_pool: [path_pool_size]u8 = undefined,
    pool_len: usize = 0,

    pub fn replace(snapshot: *Snapshot, input: SnapshotInput) !bool {
        if (snapshot.initialized and input.revision <= snapshot.revision) return false;
        if (input.entries.len > max_entries) return error.TooManyWorkspaces;
        var replacement: Snapshot = .{
            .revision = input.revision,
            .initialized = true,
            .count = input.entries.len,
        };
        for (input.entries, 0..) |entry, index| {
            if (entry.path.len > schema.max_cwd_bytes) return error.WorkspacePathTooLong;
            if (replacement.pool_len + entry.path.len > path_pool_size)
                return error.WorkspaceListTooLarge;
            for (input.entries[0..index]) |previous| {
                if (previous.workspace == entry.workspace)
                    return error.DuplicateWorkspace;
            }
            const name = truncateName(entry.name);
            var stored: Entry = .{
                .workspace = entry.workspace,
                .name = undefined,
                .name_len = @intCast(name.len),
                .path_offset = @intCast(replacement.pool_len),
                .path_len = @intCast(entry.path.len),
                .tab_count = entry.tab_count,
            };
            @memcpy(stored.name[0..name.len], name);
            @memcpy(
                replacement.path_pool[replacement.pool_len..][0..entry.path.len],
                entry.path,
            );
            replacement.pool_len += entry.path.len;
            replacement.entries[index] = stored;
        }
        snapshot.* = replacement;
        return true;
    }

    pub fn nameAt(snapshot: *const Snapshot, index: usize) []const u8 {
        const entry = &snapshot.entries[index];
        return entry.name[0..entry.name_len];
    }

    pub fn pathAt(snapshot: *const Snapshot, index: usize) []const u8 {
        const entry = &snapshot.entries[index];
        return snapshot.path_pool[entry.path_offset..][0..entry.path_len];
    }

    pub fn workspaceAt(snapshot: *const Snapshot, index: usize) schema.WorkspaceId {
        return snapshot.entries[index].workspace;
    }

    pub fn workspaceAtPosition(snapshot: *const Snapshot, position: usize) ?schema.WorkspaceId {
        if (position >= snapshot.count) return null;
        return snapshot.workspaceAt(position);
    }

    pub fn indexOf(snapshot: *const Snapshot, workspace: schema.WorkspaceId) ?usize {
        for (snapshot.entries[0..snapshot.count], 0..) |entry, index|
            if (entry.workspace == workspace) return index;
        return null;
    }
};

pub fn truncateName(name: []const u8) []const u8 {
    if (name.len <= max_name_bytes) return name;
    var end: usize = max_name_bytes;
    // Never split a UTF-8 sequence: back up over continuation bytes.
    while (end > 0 and name[end] & 0b1100_0000 == 0b1000_0000) end -= 1;
    return name[0..end];
}

test "replacement rejects stale revisions and copies into fixed storage" {
    var snapshot: Snapshot = .{};
    const entries = [_]EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/work/telar", .tab_count = 2 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 1 },
    };
    try std.testing.expect(try snapshot.replace(.{ .revision = 3, .entries = &entries }));
    try std.testing.expect(!try snapshot.replace(.{ .revision = 3, .entries = &entries }));
    try std.testing.expect(!try snapshot.replace(.{ .revision = 2, .entries = &entries }));
    try std.testing.expectEqual(@as(usize, 2), snapshot.count);
    try std.testing.expectEqualStrings("telar", snapshot.nameAt(0));
    try std.testing.expectEqualStrings("/work/api", snapshot.pathAt(1));
    try std.testing.expectEqual(@as(schema.WorkspaceId, @enumFromInt(1)), snapshot.workspaceAtPosition(0).?);
    try std.testing.expectEqual(@as(schema.WorkspaceId, @enumFromInt(2)), snapshot.workspaceAtPosition(1).?);
    try std.testing.expect(snapshot.workspaceAtPosition(2) == null);
    try std.testing.expectEqual(@as(usize, 1), snapshot.indexOf(@enumFromInt(2)).?);
    try std.testing.expect(snapshot.indexOf(@enumFromInt(9)) == null);
}

test "duplicate workspace ids are rejected" {
    var snapshot: Snapshot = .{};
    const entries = [_]EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "a", .path = "/a", .tab_count = 1 },
        .{ .workspace = @enumFromInt(1), .name = "b", .path = "/b", .tab_count = 1 },
    };
    try std.testing.expectError(
        error.DuplicateWorkspace,
        snapshot.replace(.{ .revision = 1, .entries = &entries }),
    );
}

test "long names truncate on a codepoint boundary" {
    const name = "ñ" ** 30; // 60 bytes of two-byte codepoints
    const truncated = truncateName(name);
    try std.testing.expectEqual(@as(usize, 48), truncated.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncated));
}
