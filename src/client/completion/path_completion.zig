//! Lists the directories matching one expanded query. Runs on the
//! observation path: it may block on the filesystem and allocates one
//! bounded result, never more than `Result.max_entries` names of at most
//! `Result.max_name_bytes` bytes inside `Result.max_path_bytes` paths.

const std = @import("std");
const Result = @import("../model/PathCompletionResult.zig");
const JobType = @import("PathCompletionJob.zig");

/// Splits the query at its last `/`: the part before is the directory to
/// list and the rest filters the names. Hidden directories are listed only
/// when the filter itself starts with `.`.
///
/// ```zig
/// const result = try run(io, gpa, job);
/// defer gpa.destroy(result);
/// ```
pub fn run(io: std.Io, gpa: std.mem.Allocator, job: JobType) !*Result {
    const result = try gpa.create(Result);
    errdefer gpa.destroy(result);
    result.* = .{};
    try list(io, job.querySlice(), result);
    return result;
}

/// Fills `result` without allocating; see `run` for the query rules.
pub fn list(io: std.Io, query: []const u8, result: *Result) !void {
    if (query.len == 0 or query[0] != '/') {
        return error.RelativeQuery;
    }

    const split = std.mem.lastIndexOfScalar(u8, query, '/').?;
    const base = if (split == 0) "/" else query[0..split];
    const partial = query[split + 1 ..];
    try result.setBase(base);
    result.exact_exists = partial.len == 0 or isDirectory(io, query);

    var directory = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch return;
    defer directory.close(io);
    var iterator = directory.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, partial)) {
            continue;
        }
        if (entry.name[0] == '.' and (partial.len == 0 or partial[0] != '.')) {
            continue;
        }
        if (!entryIsDirectory(io, directory, entry)) {
            continue;
        }

        result.append(entry.name) catch |err| switch (err) {
            error.TooManyEntries => break,
            error.NameTooLong => continue,
        };
    }

    result.sort();
}

fn entryIsDirectory(io: std.Io, directory: std.Io.Dir, entry: std.Io.Dir.Entry) bool {
    return switch (entry.kind) {
        .directory => true,
        .sym_link => blk: {
            const stat = directory.statFile(io, entry.name, .{}) catch break :blk false;
            break :blk stat.kind == .directory;
        },
        else => false,
    };
}

fn isDirectory(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

test "listing keeps directories only, filters the typed prefix and hides dotfiles" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "telar");
    try temp.dir.createDirPath(io, "tests");
    try temp.dir.createDirPath(io, "other");
    try temp.dir.createDirPath(io, ".git");
    const file = try temp.dir.createFile(io, "text", .{});
    file.close(io);
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    var query_buffer: [Result.max_path_bytes]u8 = undefined;

    var result: Result = .{};
    try list(io, try std.fmt.bufPrint(&query_buffer, "{s}/te", .{root}), &result);
    try std.testing.expectEqual(@as(usize, 2), result.slice().len);
    try std.testing.expectEqualStrings("telar", result.slice()[0].slice());
    try std.testing.expectEqualStrings("tests", result.slice()[1].slice());
    try std.testing.expectEqualStrings(root, result.baseSlice());
    try std.testing.expect(!result.exact_exists);

    result = .{};
    try list(io, try std.fmt.bufPrint(&query_buffer, "{s}/", .{root}), &result);
    try std.testing.expectEqual(@as(usize, 3), result.slice().len);
    try std.testing.expect(result.exact_exists);

    result = .{};
    try list(io, try std.fmt.bufPrint(&query_buffer, "{s}/.g", .{root}), &result);
    try std.testing.expectEqual(@as(usize, 1), result.slice().len);
    try std.testing.expectEqualStrings(".git", result.slice()[0].slice());

    result = .{};
    try list(io, try std.fmt.bufPrint(&query_buffer, "{s}/telar", .{root}), &result);
    try std.testing.expect(result.exact_exists);
    try std.testing.expectError(error.RelativeQuery, list(io, "relative", &result));
}

test "listing stops at the entry bound and a missing base lists nothing" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var name: [8]u8 = undefined;
    for (0..Result.max_entries + 5) |index| {
        try temp.dir.createDirPath(io, try std.fmt.bufPrint(&name, "d{d}", .{index}));
    }
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    var query_buffer: [Result.max_path_bytes]u8 = undefined;

    var result: Result = .{};
    try list(io, try std.fmt.bufPrint(&query_buffer, "{s}/d", .{root}), &result);
    try std.testing.expectEqual(@as(usize, Result.max_entries), result.slice().len);

    result = .{};
    try list(io, try std.fmt.bufPrint(&query_buffer, "{s}/missing/x", .{root}), &result);
    try std.testing.expectEqual(@as(usize, 0), result.slice().len);
    try std.testing.expect(!result.exact_exists);

    const job: JobType = .init(@enumFromInt(1), try std.fmt.bufPrint(&query_buffer, "{s}/d1", .{root}));
    const owned = try run(io, std.testing.allocator, job);
    defer std.testing.allocator.destroy(owned);
    try std.testing.expect(owned.slice().len >= 1);
}
