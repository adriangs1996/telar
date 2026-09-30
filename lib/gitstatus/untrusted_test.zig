//! A planted repository: its config names a program for every hook Git
//! offers read-only commands, and each program leaves a marker. Observation
//! must measure the repository and leave no marker.
const std = @import("std");
const builtin = @import("builtin");
const probe = @import("probe.zig");
const base_distance = @import("base_distance.zig");
const untrusted_git = @import("untrusted_git.zig");

const identity = [_][]const u8{ "-c", "user.name=telar", "-c", "user.email=telar@localhost", "-c", "commit.gpgsign=false" };
const programs = [_][]const u8{ "fsmonitor", "clean", "included", "unnamed", "textconv", "external", "hook", "configured" };

fn git(arguments: []const []const u8) !void {
    _ = try gitOutput(arguments, &.{});
}

/// Runs Git with a test identity and returns its trimmed output in `buffer`.
fn gitOutput(arguments: []const []const u8, buffer: []u8) ![]const u8 {
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

    const line = std.mem.trim(u8, result.stdout, " \r\n");
    const len = @min(line.len, buffer.len);
    @memcpy(buffer[0..len], line[0..len]);
    return buffer[0..len];
}

fn system(argv: []const []const u8) !void {
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = argv });
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
}

/// A program that records it ran and passes its input through.
fn writeMarker(temp: *std.testing.TmpDir, base: []const u8, name: []const u8) !void {
    var script_buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buffer, "#!/bin/sh\ntouch {s}/markers/{s}\ncat\n", .{ base, name });
    var path_buffer: [64]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&path_buffer, "{s}.sh", .{name});
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = script });

    var full_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try system(&.{ "chmod", "+x", try std.fmt.bufPrint(&full_buffer, "{s}/{s}", .{ base, sub_path }) });
}

fn config(repo: []const u8, key: []const u8, value: []const u8) !void {
    try git(&.{ "-C", repo, "config", key, value });
}

fn scriptPath(buffer: []u8, base: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}.sh", .{ base, name });
}

/// A repository in `temp/repo`: `main` with three files, `task` one commit
/// ahead, and every program an extracted tarball could name in its `.git`,
/// with its files' stat data stale so Git has to read them.
const Planted = struct {
    temp: std.testing.TmpDir,
    base_buffer: [std.fs.max_path_bytes]u8,
    base_len: usize,
    repo_buffer: [std.fs.max_path_bytes]u8,
    repo_len: usize,

    fn base(self: *const Planted) []const u8 {
        return self.base_buffer[0..self.base_len];
    }

    fn repo(self: *const Planted) []const u8 {
        return self.repo_buffer[0..self.repo_len];
    }

    fn deinit(self: *Planted) void {
        self.temp.cleanup();
    }

    /// Fails the test with the name of every planted program that ran.
    fn expectNothingRan(self: *Planted) !void {
        var markers = try self.temp.dir.openDir(std.testing.io, "markers", .{ .iterate = true });
        defer markers.close(std.testing.io);
        var ran = false;
        var entries = markers.iterate();
        while (try entries.next(std.testing.io)) |entry| {
            std.debug.print("a planted program ran: {s}\n", .{entry.name});
            ran = true;
        }

        if (ran) {
            return error.PlantedProgramRan;
        }
    }
};

fn plant(planted: *Planted) !void {
    const io = std.testing.io;
    planted.temp = std.testing.tmpDir(.{});
    errdefer planted.temp.cleanup();
    planted.base_len = try planted.temp.dir.realPath(io, &planted.base_buffer);
    const base = planted.base();
    planted.repo_len = (try std.fmt.bufPrint(&planted.repo_buffer, "{s}/repo", .{base})).len;
    const repo = planted.repo();

    git(&.{ "init", "-q", "-b", "main", repo }) catch return error.SkipZigTest;
    try planted.temp.dir.createDirPath(io, "markers");
    for (programs) |name| {
        try writeMarker(&planted.temp, base, name);
    }

    try planted.temp.dir.writeFile(io, .{ .sub_path = "repo/a.txt", .data = "one\ntwo\n" });
    try planted.temp.dir.writeFile(io, .{ .sub_path = "repo/b.txt", .data = "one\n" });
    try planted.temp.dir.writeFile(io, .{ .sub_path = "repo/c.txt", .data = "one\ntwo\n" });
    try git(&.{ "-C", repo, "add", "a.txt", "b.txt", "c.txt" });
    try git(&.{ "-C", repo, "commit", "-q", "-m", "one" });
    try git(&.{ "-C", repo, "checkout", "-q", "-b", "task" });
    try planted.temp.dir.writeFile(io, .{ .sub_path = "repo/b.txt", .data = "one\nmore\n" });
    try git(&.{ "-C", repo, "commit", "-q", "-am", "two" });

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try config(repo, "core.fsmonitor", try scriptPath(&path_buffer, base, "fsmonitor"));
    try config(repo, "filter.evil.clean", try scriptPath(&path_buffer, base, "clean"));
    try config(repo, "diff.evil.textconv", try scriptPath(&path_buffer, base, "textconv"));
    try config(repo, "diff.external", try scriptPath(&path_buffer, base, "external"));
    try config(repo, "hook.evil.command", try scriptPath(&path_buffer, base, "configured"));
    try config(repo, "hook.evil.event", "post-index-change");
    try config(repo, "include.path", "extra.cfg");
    var text_buffer: [2 * std.fs.max_path_bytes + 64]u8 = undefined;
    var unnamed_buffer: [std.fs.max_path_bytes]u8 = undefined;
    // `[filter ""]`: a driver whose name is empty, reached by `filter=`.
    const included = try std.fmt.bufPrint(&text_buffer, "[filter \"other\"]\n\tprocess = {s}\n[filter \"\"]\n\tclean = {s}\n", .{
        try scriptPath(&path_buffer, base, "included"),
        try scriptPath(&unnamed_buffer, base, "unnamed"),
    });
    try planted.temp.dir.writeFile(io, .{ .sub_path = "repo/.git/extra.cfg", .data = included });
    try planted.temp.dir.writeFile(io, .{ .sub_path = "repo/.git/info/attributes", .data = "a.txt filter=evil diff=evil\nb.txt filter=other diff=evil\nc.txt filter=\n" });
    try planted.temp.dir.createDirPath(io, "repo/.git/hooks");
    try planted.temp.dir.writeFile(io, .{ .sub_path = "repo/.git/hooks/post-index-change", .data = try std.fmt.bufPrint(&text_buffer, "#!/bin/sh\ntouch {s}/markers/hook\n", .{base}) });
    try system(&.{ "chmod", "+x", try std.fmt.bufPrint(&path_buffer, "{s}/.git/hooks/post-index-change", .{repo}) });

    // Same size, new content, a stale timestamp: Git has to read the files.
    try planted.temp.dir.writeFile(io, .{ .sub_path = "repo/a.txt", .data = "one\nTWO\n" });
    try planted.temp.dir.writeFile(io, .{ .sub_path = "repo/c.txt", .data = "one\nTWO\n" });
    for ([_][]const u8{ "a.txt", "c.txt" }) |name| {
        try system(&.{ "touch", "-t", "202001010000", try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ repo, name }) });
    }
}

test "observation measures a planted repository without running any program it names" {
    var planted: Planted = undefined;
    try plant(&planted);
    defer planted.deinit();
    const io = std.testing.io;

    var head: [256]u8 = undefined;
    const status = probe.run(io, std.testing.environ, planted.repo(), &head).?;
    try std.testing.expectEqualStrings("task", status.branch);
    try std.testing.expect(status.dirty.?);

    const stat = try base_distance.run(io, .{ .environ = std.testing.environ, .path = planted.repo() }, "main");
    try std.testing.expectEqual(@as(u32, 1), stat.commits_ahead);
    try std.testing.expectEqual(@as(u32, 3), stat.files);
    try planted.expectNothingRan();
}

test "the hardened options alone stop every hook, even when Git may write the index" {
    var planted: Planted = undefined;
    try plant(&planted);
    defer planted.deinit();

    // No GIT_OPTIONAL_LOCKS: `status` refreshes and writes the index, which
    // fires post-index-change from the hooks directory and from config.
    const argv = [_][]const u8{"git"} ++ untrusted_git.hardened_options ++ [_][]const u8{ "-c", "filter.evil.clean=", "-c", "filter..clean=", "-c", "filter.other.process=", "-C", planted.repo(), "status", "--porcelain" };
    try system(&argv);
    try planted.expectNothingRan();
}

test "a status Git could not finish reads as unknown, never as clean" {
    var planted: Planted = undefined;
    try plant(&planted);
    defer planted.deinit();

    try planted.temp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/.git/index", .data = "not an index" });
    var head: [256]u8 = undefined;
    const status = probe.run(std.testing.io, std.testing.environ, planted.repo(), &head).?;
    try std.testing.expectEqualStrings("task", status.branch);
    try std.testing.expect(status.dirty == null);
}

test "files named after the merge base cannot fake a worktree's numbers" {
    var planted: Planted = undefined;
    try plant(&planted);
    defer planted.deinit();
    const repo = planted.repo();

    var merge_base_buffer: [64]u8 = undefined;
    const merge_base = try gitOutput(&.{ "-C", repo, "merge-base", "main", "HEAD" }, &merge_base_buffer);
    var name_buffer: [96]u8 = undefined;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "", "..HEAD" }) |suffix| {
        const name = try std.fmt.bufPrint(&name_buffer, "{s}{s}", .{ merge_base, suffix });
        try planted.temp.dir.writeFile(std.testing.io, .{ .sub_path = try std.fmt.bufPrint(&path_buffer, "repo/{s}", .{name}), .data = "x\n" });
    }

    const stat = try base_distance.run(std.testing.io, .{ .environ = std.testing.environ, .path = repo }, "main");
    try std.testing.expectEqual(@as(u32, 1), stat.commits_ahead);
    try std.testing.expectEqual(@as(u32, 3), stat.files);
}

test "GIT_DIR and GIT_WORK_TREE in the runtime's environment redirect no probe" {
    // The environment is built as a POSIX block, which Windows has not.
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    } else {
        try expectEnvironmentRedirectsNothing();
    }
}

fn expectEnvironmentRedirectsNothing() !void {
    var planted: Planted = undefined;
    try plant(&planted);
    defer planted.deinit();
    const io = std.testing.io;

    var other_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const other = try std.fmt.bufPrint(&other_buffer, "{s}/other", .{planted.base()});
    try git(&.{ "init", "-q", "-b", "main", other });
    try planted.temp.dir.writeFile(io, .{ .sub_path = "other/o.txt", .data = "o\n" });
    try git(&.{ "-C", other, "add", "o.txt" });
    try git(&.{ "-C", other, "commit", "-q", "-m", "other" });

    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("PATH", std.testing.environ.getPosix("PATH") orelse "/usr/bin:/bin");
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var index_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try environment.put("GIT_DIR", try std.fmt.bufPrint(&dir_buffer, "{s}/.git", .{other}));
    try environment.put("GIT_WORK_TREE", other);
    try environment.put("GIT_INDEX_FILE", try std.fmt.bufPrint(&index_buffer, "{s}/.git/index", .{other}));
    var block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const environ: std.process.Environ = .{ .block = block };

    var head: [256]u8 = undefined;
    try std.testing.expect(probe.run(io, environ, planted.repo(), &head).?.dirty.?);
    const stat = try base_distance.run(io, .{ .environ = environ, .path = planted.repo() }, "main");
    try std.testing.expectEqual(@as(u32, 1), stat.commits_ahead);
}
