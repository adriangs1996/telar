//! Builds one path index off the runtime loop. Inside a git work tree the
//! index is what `git ls-files` reports, so `.gitignore` holds exactly;
//! elsewhere a breadth-first walk skips hidden entries and dependency
//! directories. Symlinks are listed, never followed.

const core = @import("telar-core");
const std = @import("std");
const PathIndex = @import("PathIndex.zig");
const gitstatus = @import("gitstatus");

/// Bound for reading the repository's config before `git ls-files` starts.
const config_read_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(2) },
};

/// How many appended entries a query waits for at most.
const publish_every = 1024;
/// Directory names a walk outside git never enters.
const skipped_directories = [_][]const u8{
    "node_modules",
    "zig-out",
    "target",
    "__pycache__",
};

/// Fills `index` for its root and marks it complete; a cancelled build
/// stops at the next entry. Runs on the observation path.
///
/// ```zig
/// try model.select.concurrent(.path_index_built, path_index_build.run, .{ index, model.io, model.inherited_environment });
/// ```
pub fn run(index: *PathIndex, io: std.Io, environ: std.process.Environ) *PathIndex {
    build(index, io, environ);
    index.publish();
    index.complete.store(true, .release);
    return index;
}

fn build(index: *PathIndex, io: std.Io, environ: std.process.Environ) void {
    const root = index.rootSlice();
    var directory = std.Io.Dir.cwd().openDir(
        io,
        root,
        .{ .iterate = true },
    ) catch {
        index.failure = .unreadable;
        return;
    };
    defer directory.close(io);

    if (insideWorkTree(io, root)) {
        listTracked(index, io, environ) catch {};
        if (index.entry_count != 0 or index.cancelled.load(.acquire)) {
            return;
        }
    }

    walk(
        index,
        io,
        directory,
    );
}

fn insideWorkTree(io: std.Io, root: []const u8) bool {
    var buffer: [core.max_cwd_bytes + "/.git".len]u8 = undefined;
    var current = std.mem.trimEnd(
        u8,
        root,
        "/",
    );
    while (true) {
        const marker = std.fmt.bufPrint(
            &buffer,
            "{s}/.git",
            .{current},
        ) catch return false;
        if (std.Io.Dir.accessAbsolute(
            io,
            marker,
            .{},
        )) {
            return true;
        } else |_| {}

        const split = std.mem.lastIndexOfScalar(
            u8,
            current,
            '/',
        ) orelse return false;
        current = current[0..split];
    }
}

/// Streams `git ls-files` into the index, adding each file's directories
/// before the file the first time they appear. The root may be any
/// repository, so Git runs with every program its config names turned off.
fn listTracked(index: *PathIndex, io: std.Io, environ: std.process.Environ) !void {
    var child = gitstatus.untrusted_git.spawn(io, .{
        .environ = environ,
        .path = index.rootSlice(),
        .arguments = &.{ "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
        .timeout = config_read_timeout,
        .stdout_limit = 0,
    }) orelse return error.GitUnavailable;
    defer child.kill(io);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(index.gpa);

    var buffer: [core.max_cwd_bytes]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buffer);
    while (try reader.interface.takeDelimiter(0)) |relative| {
        if (index.cancelled.load(.acquire)) {
            return;
        }

        if (!acceptable(relative)) {
            continue;
        }

        if (!try addParents(
            index,
            &seen,
            relative,
        )) {
            return;
        }

        if (!append(
            index,
            relative,
            .file,
        )) {
            return;
        }
    }
}

/// Adds the directories of `relative` not seen yet; false once the index is full.
fn addParents(index: *PathIndex, seen: *std.StringHashMapUnmanaged(void), relative: []const u8) !bool {
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(
        u8,
        relative,
        start,
        '/',
    )) |split| {
        start = split + 1;
        const directory = relative[0..start];
        if (seen.contains(directory)) {
            continue;
        }

        const offset = index.bytes_used;
        if (!append(
            index,
            directory,
            .directory,
        )) {
            return false;
        }

        try seen.put(
            index.gpa,
            index.bytes[offset..][0..directory.len],
            {},
        );
    }

    return true;
}

/// Lists the root, then every directory in the order it was indexed, so a
/// shallow path always precedes a deeper one.
fn walk(index: *PathIndex, io: std.Io, root: std.Io.Dir) void {
    listDirectory(
        index,
        io,
        .{
            .directory = root,
            .prefix = "",
        },
    );

    var cursor: u32 = 0;
    while (cursor < index.entry_count) : (cursor += 1) {
        if (index.cancelled.load(.acquire) or index.truncated) {
            return;
        }

        const entry = index.entries[cursor];
        if (entry.kind != .directory) {
            continue;
        }

        const prefix = index.path(entry);
        var child = root.openDir(
            io,
            prefix[0 .. prefix.len - 1],
            .{ .iterate = true },
        ) catch continue;
        defer child.close(io);

        listDirectory(
            index,
            io,
            .{
                .directory = child,
                .prefix = prefix,
            },
        );
    }
}

const Listing = struct {
    directory: std.Io.Dir,
    /// The directory's own path relative to the root, ending in `/`.
    prefix: []const u8,
};

fn listDirectory(index: *PathIndex, io: std.Io, listing: Listing) void {
    var buffer: [core.max_path_match_bytes]u8 = undefined;
    var iterator = listing.directory.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.name[0] == '.') {
            continue;
        }

        const directory = entry.kind == .directory;
        if (directory and isSkipped(entry.name)) {
            continue;
        }

        const suffix: []const u8 = if (directory) "/" else "";
        const relative = std.fmt.bufPrint(
            &buffer,
            "{s}{s}{s}",
            .{ listing.prefix, entry.name, suffix },
        ) catch continue;
        if (!acceptable(relative)) {
            continue;
        }

        if (!append(
            index,
            relative,
            if (directory) .directory else .file,
        )) {
            return;
        }
    }
}

fn isSkipped(name: []const u8) bool {
    for (skipped_directories) |skipped| {
        if (std.mem.eql(
            u8,
            name,
            skipped,
        )) {
            return true;
        }
    }

    return false;
}

/// A path the wire can carry and a pane can receive: bounded, UTF-8 and
/// free of control bytes.
fn acceptable(relative: []const u8) bool {
    if (relative.len == 0 or relative.len > core.max_path_match_bytes or !std.unicode.utf8ValidateSlice(relative)) {
        return false;
    }

    for (relative) |byte| {
        if (std.ascii.isControl(byte)) {
            return false;
        }
    }

    return true;
}

fn append(index: *PathIndex, relative: []const u8, kind: core.PathKind) bool {
    if (!index.append(relative, kind)) {
        return false;
    }

    if (index.entry_count % publish_every == 0) {
        index.publish();
    }

    return true;
}

const testing = std.testing;

fn buildIn(temp: *testing.TmpDir, index: *PathIndex) !void {
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(testing.io, &root_buffer)];
    index.want(root, true);
    index.reset();
    _ = run(index, testing.io, testing.environ);
}

fn contains(index: *const PathIndex, relative: []const u8) bool {
    for (index.entries[0..index.published.load(.acquire)]) |entry| {
        if (std.mem.eql(
            u8,
            index.path(entry),
            relative,
        )) {
            return true;
        }
    }

    return false;
}

test "a walk lists shallow entries first and skips hidden and dependency directories" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.createDirPath(testing.io, "src/types");
    try temp.dir.createDirPath(testing.io, "node_modules/left-pad");
    try temp.dir.createDirPath(testing.io, ".cache");
    const file = try temp.dir.createFile(
        testing.io,
        "src/types/License.ts",
        .{},
    );
    file.close(testing.io);

    const index = try PathIndex.create(
        testing.allocator,
        .{
            .id = 1,
            .generation = 1,
        },
    );
    defer index.destroy();

    try buildIn(&temp, index);
    try testing.expect(index.complete.load(.acquire));
    try testing.expectEqualStrings("src/", index.path(index.entries[0]));
    try testing.expect(contains(index, "src/types/License.ts"));
    try testing.expect(contains(index, "src/types/"));
    try testing.expect(!contains(index, "node_modules/"));
    try testing.expect(!contains(index, ".cache/"));
}

test "listing a planted repository runs no program its config names" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(testing.io, &root_buffer)];
    var repo_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const repo = try std.fmt.bufPrint(&repo_buffer, "{s}/repo", .{root});
    const init = std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "git", "init", "-q", repo } }) catch return error.SkipZigTest;
    testing.allocator.free(init.stdout);
    testing.allocator.free(init.stderr);

    // `ls-files --others` asks core.fsmonitor which files changed.
    var script_buffer: [std.fs.max_path_bytes + 32]u8 = undefined;
    try temp.dir.writeFile(testing.io, .{ .sub_path = "fsmonitor.sh", .data = try std.fmt.bufPrint(&script_buffer, "#!/bin/sh\ntouch {s}/ran\n", .{root}) });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const script = try std.fmt.bufPrint(&path_buffer, "{s}/fsmonitor.sh", .{root});
    for ([_][]const []const u8{
        &.{ "chmod", "+x", script },
        &.{ "git", "-C", repo, "config", "core.fsmonitor", script },
    }) |argv| {
        const result = try std.process.run(testing.allocator, testing.io, .{ .argv = argv });
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }

    try temp.dir.writeFile(testing.io, .{ .sub_path = "repo/notes.txt", .data = "" });
    const index = try PathIndex.create(testing.allocator, .{ .id = 1, .generation = 1 });
    defer index.destroy();
    index.want(repo, true);
    index.reset();
    _ = run(index, testing.io, testing.environ);

    try testing.expect(contains(index, "notes.txt"));
    try testing.expectError(error.FileNotFound, temp.dir.statFile(testing.io, "ran", .{}));
}

test "inside a git work tree the index is what git lists, ignores included" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(testing.io, &root_buffer)];
    const init = std.process.run(
        testing.allocator,
        testing.io,
        .{ .argv = &.{ "git", "-C", root, "init", "-q" } },
    ) catch return error.SkipZigTest;
    testing.allocator.free(init.stdout);
    testing.allocator.free(init.stderr);

    try temp.dir.createDirPath(testing.io, "src/types");
    try temp.dir.createDirPath(testing.io, "build/out");
    try temp.dir.writeFile(
        testing.io,
        .{
            .sub_path = ".gitignore",
            .data = "build/\n",
        },
    );
    try temp.dir.writeFile(
        testing.io,
        .{
            .sub_path = "src/types/License.ts",
            .data = "",
        },
    );
    try temp.dir.writeFile(
        testing.io,
        .{
            .sub_path = "build/out/bundle.js",
            .data = "",
        },
    );

    const index = try PathIndex.create(
        testing.allocator,
        .{
            .id = 1,
            .generation = 1,
        },
    );
    defer index.destroy();

    try buildIn(&temp, index);
    try testing.expect(contains(index, "src/"));
    try testing.expect(contains(index, "src/types/"));
    try testing.expect(contains(index, "src/types/License.ts"));
    try testing.expect(contains(index, ".gitignore"));
    try testing.expect(!contains(index, "build/"));
    try testing.expect(!contains(index, "build/out/bundle.js"));
}

test "an unreadable root fails the build without entries" {
    const index = try PathIndex.create(
        testing.allocator,
        .{
            .id = 1,
            .generation = 1,
        },
    );
    defer index.destroy();

    index.want("/nonexistent/telar-path-picker", true);
    index.reset();
    _ = run(index, testing.io, testing.environ);
    try testing.expectEqual(PathIndex.Failure.unreadable, index.failure);
    try testing.expectEqual(@as(u32, 0), index.published.load(.acquire));
}

test "a cancelled build stops before listing" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.createDirPath(testing.io, "a/b");
    const index = try PathIndex.create(
        testing.allocator,
        .{
            .id = 1,
            .generation = 1,
        },
    );
    defer index.destroy();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(testing.io, &root_buffer)];
    index.want(root, true);
    index.reset();
    index.cancelled.store(true, .release);
    _ = run(index, testing.io, testing.environ);
    try testing.expect(index.entry_count <= 1);
}
