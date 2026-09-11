//! Bounded replica of the runtime's open-workspace list.
//!
//! The runtime owns workspace truth. One disposable client model keeps this
//! fixed-capacity value for navigation and presentation. Newer revisions
//! replace it atomically; stale or oversized snapshots preserve the last
//! usable value.

const WorkspaceListSnapshot = @import("WorkspaceListSnapshot.zig");
const EntryInput = @import("EntryInput.zig");
const std = @import("std");
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;

/// Display cap; truncation never ends inside a UTF-8 continuation sequence.
pub const max_name_bytes = 48;
/// One shared pool for every stored path. Paths stay whole so the replica
/// never exposes a fabricated location. A snapshot that cannot fit is rejected.
pub const path_pool_size = 16 * 1024;

/// Truncates one display name without ending inside a continuation sequence.
///
/// ```zig
/// const label = truncateName(long_name);
/// ```
pub fn truncateName(name: []const u8) []const u8 {
    if (name.len <= max_name_bytes) {
        return name;
    }

    var end: usize = max_name_bytes;
    while (end > 0 and name[end] & 0b1100_0000 == 0b1000_0000) {
        end -= 1;
    }

    return name[0..end];
}

test "replacement rejects stale revisions and copies into fixed storage" {
    var snapshot: WorkspaceListSnapshot = .{};
    const entries = [_]EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/work/telar", .tab_count = 2 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/work/api", .tab_count = 1 },
    };

    try std.testing.expect(!try snapshot.replace(.{ .revision = 0, .entries = &entries }));
    try std.testing.expect(try snapshot.replace(.{ .revision = 3, .entries = &entries }));
    try std.testing.expect(!try snapshot.replace(.{ .revision = 3, .entries = &entries }));
    try std.testing.expect(!try snapshot.replace(.{ .revision = 2, .entries = &entries }));
    try std.testing.expectEqual(@as(usize, 2), snapshot.count);
    try std.testing.expectEqualStrings("telar", snapshot.nameAt(0));
    try std.testing.expectEqualStrings("/work/api", snapshot.pathAt(1));
    try std.testing.expectEqual(@as(WorkspaceIdType, @enumFromInt(1)), snapshot.workspaceAtPosition(0).?);
    try std.testing.expectEqual(@as(WorkspaceIdType, @enumFromInt(2)), snapshot.workspaceAtPosition(1).?);
    try std.testing.expect(snapshot.workspaceAtPosition(2) == null);
    try std.testing.expectEqual(@as(usize, 1), snapshot.indexOf(@enumFromInt(2)).?);
    try std.testing.expect(snapshot.indexOf(@enumFromInt(9)) == null);
}

test "failed replacement preserves the last usable snapshot" {
    var snapshot: WorkspaceListSnapshot = .{};
    const original = [_]EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/work/telar", .tab_count = 2 },
    };
    try std.testing.expect(try snapshot.replace(.{ .revision = 1, .entries = &original }));

    const large_path: [max_cwd_bytes_module]u8 = @splat('x');
    const oversized = [_]EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "one", .path = &large_path, .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "two", .path = &large_path, .tab_count = 1 },
        .{ .workspace = @enumFromInt(3), .name = "three", .path = &large_path, .tab_count = 1 },
        .{ .workspace = @enumFromInt(4), .name = "four", .path = &large_path, .tab_count = 1 },
        .{ .workspace = @enumFromInt(5), .name = "five", .path = &large_path, .tab_count = 1 },
    };

    try std.testing.expectError(error.WorkspaceListTooLarge, snapshot.replace(.{
        .revision = 2,
        .entries = &oversized,
    }));
    try std.testing.expectEqual(@as(u64, 1), snapshot.revision);
    try std.testing.expectEqual(@as(usize, 1), snapshot.count);
    try std.testing.expectEqualStrings("telar", snapshot.nameAt(0));
    try std.testing.expectEqualStrings("/work/telar", snapshot.pathAt(0));
}

test "duplicate workspace ids are rejected" {
    var snapshot: WorkspaceListSnapshot = .{};
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
    const name = "ñ" ** 30;
    const truncated = truncateName(name);

    try std.testing.expectEqual(@as(usize, 48), truncated.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncated));
}
