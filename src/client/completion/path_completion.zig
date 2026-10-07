//! Lists the directories matching one expanded query. Runs on the
//! observation path: it may block on the filesystem and allocates one
//! bounded result, never more than `Result.max_entries` names of at most
//! `Result.max_name_bytes` bytes inside `Result.max_path_bytes` paths.

const data = @import("model");
const std = @import("std");
const PathCompletionJob = @import("PathCompletionJob.zig");

/// Splits the query at its last `/`: the part before is the directory to
/// list and the rest filters the names. Hidden directories are listed only
/// when the filter itself starts with `.`.
///
/// ```zig
/// const result = try run(io, gpa, job);
/// defer gpa.destroy(result);
/// ```
pub fn run(io: std.Io, gpa: std.mem.Allocator, job: PathCompletionJob) !*data.PathCompletionResult {
    const result = try gpa.create(data.PathCompletionResult);
    errdefer gpa.destroy(result);
    result.* = .{};
    try list(io, job.querySlice(), result);
    return result;
}

/// Fills `result` without allocating; see `run` for the query rules.
pub fn list(io: std.Io, query: []const u8, result: *data.PathCompletionResult) !void {
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

        result.keep(entry.name) catch |err| switch (err) {
            error.TooManyEntries, error.PathEntryTooLong => continue,
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
