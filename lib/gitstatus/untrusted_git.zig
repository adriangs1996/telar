//! Git run on its own in a repository nobody vouched for: a checkout a shell
//! entered, a tarball the user extracted. Such a repository passes
//! `safe.directory` (the user owns it), yet its own config can name programs
//! that read-only commands run. Checked against Git 2.55:
//!
//! - `status` runs `core.fsmonitor` and, when it refreshes the index, the
//!   `post-index-change` hook;
//! - `status` and `diff` run a filter driver's `clean` (or `process`) on a
//!   file whose stat data went stale, whether `.gitattributes` or
//!   `.git/info/attributes` names it;
//! - `diff` runs `diff.external` and a diff driver's `textconv`;
//! - a partial clone fetches missing objects lazily through its promisor
//!   remote, running its `uploadpack` or `core.sshCommand`.
//!
//! Every call here turns each of them off, so observation never runs a
//! program the repository chose.
const std = @import("std");
const GitRequest = @import("GitRequest.zig");
const GitOutput = @import("GitOutput.zig");

/// Filter drivers the repository may define before it is refused outright.
pub const max_filter_drivers = 8;

const max_arguments = 64;
const max_stderr_bytes = 4096;
const max_config_bytes = 64 * 1024;

/// Options that stop Git from running `core.fsmonitor` or any hook.
const hardened_options = [_][]const u8{
    "-c", "core.fsmonitor=false",
    "-c", "core.hooksPath=/dev/null",
};

/// No index write (so no `post-index-change`), no lazy fetch (Git 2.45 and
/// later; older Git ignores it) and no credential prompt.
const hardened_environment = [_][2][]const u8{
    .{ "GIT_OPTIONAL_LOCKS", "0" },
    .{ "GIT_NO_LAZY_FETCH", "1" },
    .{ "GIT_TERMINAL_PROMPT", "0" },
};

const filter_keys = [_][]const u8{ "clean", "smudge", "process" };

/// Runs one read-only Git command with every repository-chosen program
/// turned off. Null when Git fails, times out, or the repository defines
/// filter drivers that cannot be turned off safely.
///
/// ```zig
/// const output = untrusted_git.run(io, .{ .environ = environ, .path = path, .arguments = &.{ "status", "--porcelain" }, .timeout = timeout, .stdout_limit = 4096 }) orelse return null;
/// defer output.deinit();
/// ```
pub fn run(io: std.Io, request: GitRequest) ?GitOutput {
    const gpa = std.heap.page_allocator;
    var environ_map = request.environ.createMap(gpa) catch return null;
    defer environ_map.deinit();
    for (hardened_environment) |entry| {
        environ_map.put(entry[0], entry[1]) catch return null;
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var drivers: [max_filter_drivers][]const u8 = undefined;
    const driver_count = localFilterDrivers(io, request, &environ_map, arena, &drivers) orelse return null;

    var argv: [max_arguments][]const u8 = undefined;
    var len: usize = 0;
    argv[len] = "git";
    len += 1;
    for (hardened_options) |option| {
        argv[len] = option;
        len += 1;
    }

    // An empty command turns the driver off; Git then compares raw content.
    for (drivers[0..driver_count]) |driver| {
        for (filter_keys) |key| {
            argv[len] = "-c";
            argv[len + 1] = std.fmt.allocPrint(arena, "filter.{s}.{s}=", .{ driver, key }) catch return null;
            len += 2;
        }
    }

    if (len + 2 + request.arguments.len > argv.len) {
        return null;
    }

    argv[len] = "-C";
    argv[len + 1] = request.path;
    len += 2;
    for (request.arguments) |argument| {
        argv[len] = argument;
        len += 1;
    }

    return spawn(io, .{
        .argv = argv[0..len],
        .environ_map = &environ_map,
        .timeout = request.timeout,
        .stdout_limit = request.stdout_limit,
    });
}

const Spawn = struct {
    argv: []const []const u8,
    environ_map: *const std.process.Environ.Map,
    timeout: std.Io.Timeout,
    stdout_limit: usize,
};

fn spawn(io: std.Io, command: Spawn) ?GitOutput {
    const gpa = std.heap.page_allocator;
    const result = std.process.run(gpa, io, .{
        .argv = command.argv,
        .stdout_limit = .limited(command.stdout_limit),
        .stderr_limit = .limited(max_stderr_bytes),
        .timeout = command.timeout,
        .environ_map = command.environ_map,
    }) catch return null;
    gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        gpa.free(result.stdout);
        return null;
    }

    return .{ .stdout = result.stdout };
}

/// The filter drivers the repository's own config defines (local and
/// worktree scope, including files it includes). The user's global and
/// system drivers, such as Git LFS, stay trusted. Reading config runs no
/// program. Null when there are too many drivers or a name `-c` cannot carry.
/// The names are copied into `arena`.
fn localFilterDrivers(io: std.Io, request: GitRequest, environ_map: *const std.process.Environ.Map, arena: std.mem.Allocator, drivers: *[max_filter_drivers][]const u8) ?usize {
    const argv = hardened_options ++ [_][]const u8{ "-C", request.path, "config", "--show-scope", "-z", "--get-regexp", "^filter\\." };
    const gpa = std.heap.page_allocator;
    const result = std.process.run(gpa, io, .{
        .argv = &([_][]const u8{"git"} ++ argv),
        .stdout_limit = .limited(max_config_bytes),
        .stderr_limit = .limited(max_stderr_bytes),
        .timeout = request.timeout,
        .environ_map = environ_map,
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited) {
        return null;
    }

    // `git config --get-regexp` exits 1 when nothing matches.
    switch (result.term.exited) {
        0 => {},
        1 => return 0,
        else => return null,
    }

    const count = parseDrivers(result.stdout, drivers) orelse return null;
    for (drivers[0..count]) |*driver| {
        driver.* = arena.dupe(u8, driver.*) catch return null;
    }

    return count;
}

/// Reads `scope\0key\nvalue\0` records into distinct driver names that
/// borrow `listing`.
fn parseDrivers(listing: []const u8, drivers: *[max_filter_drivers][]const u8) ?usize {
    var count: usize = 0;
    var fields = std.mem.splitScalar(u8, listing, 0);
    while (fields.next()) |scope| {
        if (scope.len == 0) {
            break;
        }

        const entry = fields.next() orelse return null;
        if (!std.mem.eql(u8, scope, "local") and !std.mem.eql(u8, scope, "worktree")) {
            continue;
        }

        const key_end = std.mem.indexOfScalar(u8, entry, '\n') orelse entry.len;
        const key = entry[0..key_end];
        const variable_start = std.mem.lastIndexOfScalar(u8, key, '.') orelse return null;
        if (!std.mem.startsWith(u8, key, "filter.") or variable_start <= "filter.".len) {
            continue;
        }

        const name = key["filter.".len..variable_start];
        if (std.mem.indexOfAny(u8, name, "=\n\x00") != null) {
            return null;
        }

        const known = for (drivers[0..count]) |driver| {
            if (std.mem.eql(u8, driver, name)) {
                break true;
            }
        } else false;
        if (known) {
            continue;
        }

        if (count == max_filter_drivers) {
            return null;
        }

        drivers[count] = name;
        count += 1;
    }

    return count;
}

test "filter drivers come from the repository's own scopes only" {
    var drivers: [max_filter_drivers][]const u8 = undefined;
    const listing = "local\x00filter.evil.clean\n/tmp/x\x00local\x00filter.evil.smudge\ncat\x00" ++
        "global\x00filter.lfs.clean\ngit-lfs clean -- %f\x00worktree\x00filter.sp ace.process\ny\x00";
    const count = parseDrivers(listing, &drivers).?;
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("evil", drivers[0]);
    try std.testing.expectEqualStrings("sp ace", drivers[1]);

    try std.testing.expectEqual(@as(usize, 0), parseDrivers("", &drivers).?);
    try std.testing.expect(parseDrivers("local\x00filter.a=b.clean\nx\x00", &drivers) == null);
}
