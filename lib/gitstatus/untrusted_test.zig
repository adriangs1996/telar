//! A planted repository: its config names a program for every hook Git
//! offers read-only commands, and each program leaves a marker. Observation
//! must measure the repository and leave no marker.
const std = @import("std");
const probe = @import("probe.zig");
const base_distance = @import("base_distance.zig");

const identity = [_][]const u8{ "-c", "user.name=telar", "-c", "user.email=telar@localhost", "-c", "commit.gpgsign=false" };
const programs = [_][]const u8{ "fsmonitor", "clean", "included", "textconv", "external", "hook" };

fn git(arguments: []const []const u8) !void {
    var argv: [24][]const u8 = undefined;
    argv[0] = "git";
    @memcpy(argv[1 .. 1 + identity.len], &identity);
    @memcpy(argv[1 + identity.len ..][0..arguments.len], arguments);
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = argv[0 .. 1 + identity.len + arguments.len] });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return error.GitFailed;
    }
}

/// A program that records it ran and passes its input through.
fn writeMarker(temp: *std.testing.TmpDir, base: []const u8, name: []const u8) !void {
    var script_buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buffer, "#!/bin/sh\ntouch {s}/markers/{s}\ncat\n", .{ base, name });
    var path_buffer: [64]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&path_buffer, "{s}.sh", .{name});
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = script });

    var full_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const full = try std.fmt.bufPrint(&full_buffer, "{s}/{s}", .{ base, sub_path });
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "chmod", "+x", full } });
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
}

fn config(repo: []const u8, key: []const u8, value: []const u8) !void {
    try git(&.{ "-C", repo, "config", key, value });
}

fn scriptPath(buffer: []u8, base: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}.sh", .{ base, name });
}

test "observation measures a planted repository without running any program it names" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buffer[0..try temp.dir.realPath(io, &base_buffer)];
    var repo_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const repo = try std.fmt.bufPrint(&repo_buffer, "{s}/repo", .{base});

    git(&.{ "init", "-q", "-b", "main", repo }) catch return error.SkipZigTest;
    try temp.dir.createDirPath(io, "markers");
    for (programs) |name| {
        try writeMarker(&temp, base, name);
    }

    try temp.dir.writeFile(io, .{ .sub_path = "repo/a.txt", .data = "one\ntwo\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "repo/b.txt", .data = "one\n" });
    try git(&.{ "-C", repo, "add", "a.txt", "b.txt" });
    try git(&.{ "-C", repo, "commit", "-q", "-m", "one" });
    try git(&.{ "-C", repo, "checkout", "-q", "-b", "task" });
    try temp.dir.writeFile(io, .{ .sub_path = "repo/b.txt", .data = "one\nmore\n" });
    try git(&.{ "-C", repo, "commit", "-q", "-am", "two" });

    // What an extracted tarball could carry in .git.
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try config(repo, "core.fsmonitor", try scriptPath(&path_buffer, base, "fsmonitor"));
    try config(repo, "filter.evil.clean", try scriptPath(&path_buffer, base, "clean"));
    try config(repo, "diff.evil.textconv", try scriptPath(&path_buffer, base, "textconv"));
    try config(repo, "diff.external", try scriptPath(&path_buffer, base, "external"));
    try config(repo, "include.path", "extra.cfg");
    var included_buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
    const included = try std.fmt.bufPrint(&included_buffer, "[filter \"other\"]\n\tprocess = {s}\n", .{try scriptPath(&path_buffer, base, "included")});
    try temp.dir.writeFile(io, .{ .sub_path = "repo/.git/extra.cfg", .data = included });
    try temp.dir.writeFile(io, .{ .sub_path = "repo/.git/info/attributes", .data = "a.txt filter=evil diff=evil\nb.txt filter=other diff=evil\n" });
    try temp.dir.createDirPath(io, "repo/.git/hooks");
    try temp.dir.writeFile(io, .{ .sub_path = "repo/.git/hooks/post-index-change", .data = try std.fmt.bufPrint(&included_buffer, "#!/bin/sh\ntouch {s}/markers/hook\n", .{base}) });
    const hook = try std.fmt.bufPrint(&path_buffer, "{s}/.git/hooks/post-index-change", .{repo});
    const chmod = try std.process.run(std.testing.allocator, io, .{ .argv = &.{ "chmod", "+x", hook } });
    std.testing.allocator.free(chmod.stdout);
    std.testing.allocator.free(chmod.stderr);

    // Same size, new content, a stale timestamp: Git has to read the files.
    try temp.dir.writeFile(io, .{ .sub_path = "repo/a.txt", .data = "one\nTWO\n" });
    const touch = try std.process.run(std.testing.allocator, io, .{ .argv = &.{ "touch", "-t", "202001010000", try std.fmt.bufPrint(&path_buffer, "{s}/a.txt", .{repo}) } });
    std.testing.allocator.free(touch.stdout);
    std.testing.allocator.free(touch.stderr);

    var head: [256]u8 = undefined;
    const status = probe.run(io, std.testing.environ, repo, &head).?;
    try std.testing.expectEqualStrings("task", status.branch);
    try std.testing.expect(status.dirty);

    const stat = base_distance.run(io, .{ .environ = std.testing.environ, .path = repo }, "main").?;
    try std.testing.expectEqual(@as(u32, 1), stat.commits_ahead);
    try std.testing.expectEqual(@as(u32, 2), stat.files);

    var markers = try temp.dir.openDir(io, "markers", .{ .iterate = true });
    defer markers.close(io);
    var entries = markers.iterate();
    while (try entries.next(io)) |entry| {
        std.debug.print("a planted program ran: {s}\n", .{entry.name});
        return error.PlantedProgramRan;
    }
}
