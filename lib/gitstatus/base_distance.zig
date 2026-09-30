//! Measures a worktree against the branch it came from with bounded `git`
//! children: `merge-base`, `diff --shortstat` and `rev-list --count`. Runs
//! several processes, so callers run it on a worker.
const std = @import("std");
const DiffStat = @import("DiffStat.zig");
const untrusted_git = @import("untrusted_git.zig");
const Checkout = @import("Checkout.zig");

const max_output_bytes = 4096;

/// How long each of the three Git steps may take. `diff --shortstat` on a
/// large branch takes seconds; the measurement runs on a worker.
pub const git_timeout_ms = 10 * std.time.ms_per_s;

const git_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromMilliseconds(git_timeout_ms) },
};

/// Measures `checkout` against `base`, or an error when any Git step fails
/// (`error.GitFailed`) or runs past `git_timeout_ms` (`error.GitTimedOut`),
/// so a failure never reads as "no changes". Uncommitted
/// changes to tracked files count. Revisions end at `--`, so a file named
/// after the merge base cannot turn them into paths. Git runs with every
/// repository-chosen program turned off (`untrusted_git`).
///
/// ```zig
/// const stat = gitstatus.base_distance.run(io, .{ .environ = environ, .path = "/src/fix" }, "main") catch return;
/// ```
pub fn run(io: std.Io, checkout: Checkout, base: []const u8) untrusted_git.RunError!DiffStat {
    if (base.len == 0 or base[0] == '-') {
        return error.GitFailed;
    }

    var merge_base_buffer: [64]u8 = undefined;
    const merge_base = try gitLine(io, checkout, &.{ "merge-base", base, "HEAD" }, &merge_base_buffer);
    var stat: DiffStat = .{};

    var shortstat_buffer: [max_output_bytes]u8 = undefined;
    const diff = [_][]const u8{ "diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--shortstat", merge_base, "--" };
    const shortstat = try gitLine(io, checkout, &diff, &shortstat_buffer);
    parseShortstat(shortstat, &stat);

    var range_buffer: [160]u8 = undefined;
    const range = std.fmt.bufPrint(&range_buffer, "{s}..HEAD", .{merge_base}) catch return error.GitFailed;
    var count_buffer: [32]u8 = undefined;
    const count = try gitLine(io, checkout, &.{ "rev-list", "--count", range, "--" }, &count_buffer);
    stat.commits_ahead = std.fmt.parseUnsigned(u32, count, 10) catch return error.GitFailed;
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

fn gitLine(io: std.Io, checkout: Checkout, arguments: []const []const u8, buffer: []u8) untrusted_git.RunError![]const u8 {
    const output = try untrusted_git.run(io, .{
        .environ = checkout.environ,
        .path = checkout.path,
        .arguments = arguments,
        .timeout = git_timeout,
        .stdout = .{ .fail_past = max_output_bytes },
    });
    defer output.deinit();

    const line = output.line();
    if (line.len > buffer.len) {
        return error.GitFailed;
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
