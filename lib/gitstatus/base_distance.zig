//! Measures a worktree against the branch it came from with bounded `git`
//! children: `merge-base`, `diff --shortstat` and `rev-list --count`. Runs
//! several processes, so callers run it on a worker.
const std = @import("std");
const DiffStat = @import("DiffStat.zig");

const max_output_bytes = 4096;

const git_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(2) },
};

/// Measures the checkout at `path` against `base`, or null when Git fails
/// or runs out of time. Uncommitted changes to tracked files count.
///
/// ```zig
/// const stat = gitstatus.base_distance.run(io, "/src/fix", "main") orelse return;
/// ```
pub fn run(io: std.Io, path: []const u8, base: []const u8) ?DiffStat {
    const gpa = std.heap.page_allocator;
    if (base.len == 0 or base[0] == '-') {
        return null;
    }

    var merge_base_buffer: [64]u8 = undefined;
    const merge_base = gitLine(io, gpa, &.{ "git", "-C", path, "merge-base", base, "HEAD" }, &merge_base_buffer) orelse return null;
    var stat: DiffStat = .{};

    var shortstat_buffer: [max_output_bytes]u8 = undefined;
    const shortstat = gitLine(io, gpa, &.{ "git", "-C", path, "diff", "--shortstat", merge_base }, &shortstat_buffer) orelse "";
    parseShortstat(shortstat, &stat);

    var range_buffer: [160]u8 = undefined;
    const range = std.fmt.bufPrint(&range_buffer, "{s}..HEAD", .{merge_base}) catch return null;
    var count_buffer: [32]u8 = undefined;
    const count = gitLine(io, gpa, &.{ "git", "-C", path, "rev-list", "--count", range }, &count_buffer) orelse "0";
    stat.commits_ahead = std.fmt.parseUnsigned(u32, count, 10) catch 0;
    return stat;
}

/// Reads ` 3 files changed, 12 insertions(+), 4 deletions(-)`.
///
/// ```zig
/// parseShortstat(" 1 file changed, 2 insertions(+)", &stat);
/// ```
pub fn parseShortstat(line: []const u8, stat: *DiffStat) void {
    var parts = std.mem.tokenizeScalar(u8, line, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \n");
        const space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse continue;
        const value = std.fmt.parseUnsigned(u32, trimmed[0..space], 10) catch continue;
        const label = trimmed[space + 1 ..];
        if (std.mem.startsWith(u8, label, "file")) {
            stat.files = value;
        } else if (std.mem.startsWith(u8, label, "insertion")) {
            stat.added = value;
        } else if (std.mem.startsWith(u8, label, "deletion")) {
            stat.removed = value;
        }
    }
}

fn gitLine(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8, buffer: []u8) ?[]const u8 {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
        .timeout = git_timeout,
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return null;
    }

    const line = std.mem.trim(u8, result.stdout, " \r\n");
    if (line.len > buffer.len) {
        return null;
    }

    @memcpy(buffer[0..line.len], line);
    return buffer[0..line.len];
}

test "shortstat lines parse every counter and tolerate missing ones" {
    var stat: DiffStat = .{};
    parseShortstat(" 3 files changed, 12 insertions(+), 4 deletions(-)\n", &stat);
    try std.testing.expectEqual(@as(u32, 3), stat.files);
    try std.testing.expectEqual(@as(u32, 12), stat.added);
    try std.testing.expectEqual(@as(u32, 4), stat.removed);

    var single: DiffStat = .{};
    parseShortstat(" 1 file changed, 1 deletion(-)", &single);
    try std.testing.expectEqual(@as(u32, 1), single.files);
    try std.testing.expectEqual(@as(u32, 0), single.added);
    try std.testing.expectEqual(@as(u32, 1), single.removed);
}
