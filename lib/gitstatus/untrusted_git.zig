//! Git run on its own in a repository nobody vouched for: a checkout a shell
//! entered, a tarball the user extracted. Such a repository passes
//! `safe.directory` (the user owns it), yet its own config can name programs
//! that read-only commands run. Checked against Git 2.55:
//!
//! - `status` runs `core.fsmonitor` and, when it refreshes the index, the
//!   `post-index-change` hook, from the hooks directory or from config
//!   (`hook.<name>.command` with `hook.<name>.event`);
//! - `status` and `diff` run a filter driver's `clean` (or `process`) on a
//!   file whose stat data went stale, whether `.gitattributes` or
//!   `.git/info/attributes` names it, even a driver named `""`;
//! - `diff` runs `diff.external` and a diff driver's `textconv`;
//! - a partial clone fetches missing objects lazily through its promisor
//!   remote, running its `uploadpack` or `core.sshCommand`;
//! - `GIT_DIR`, `GIT_WORK_TREE` and their kin in the environment point Git
//!   at another repository than the one asked about.
//!
//! Every call here turns each of them off, so observation never runs a
//! program the repository chose.
const std = @import("std");
const childoutput = @import("childoutput");
const GitRequest = @import("GitRequest.zig");
const GitOutput = @import("GitOutput.zig");
const ChildOutput = childoutput.ChildOutput;

/// Filter drivers the repository may define before it is refused outright.
pub const max_filter_drivers = 8;

const max_arguments = 128;
const max_config_bytes = 64 * 1024;
/// Longest `git version` line read.
const max_version_bytes = 256;

/// Why a hardened Git command gave no output.
pub const RunError = error{
    /// Git could not run safely, failed, or printed more than asked for.
    GitFailed,
    /// Git ran past the request's timeout and was stopped.
    GitTimedOut,
};

/// Every hook event `githooks(5)` lists for Git 2.55. `hook.<event>.enabled`
/// turns off every hook of that event, from the hooks directory or config.
const hook_events = [_][]const u8{
    "applypatch-msg",   "pre-applypatch",        "post-applypatch",    "pre-commit",
    "pre-merge-commit", "prepare-commit-msg",    "commit-msg",         "post-commit",
    "pre-rebase",       "post-checkout",         "post-merge",         "pre-push",
    "pre-receive",      "update",                "proc-receive",       "post-receive",
    "post-update",      "reference-transaction", "push-to-checkout",   "pre-auto-gc",
    "post-rewrite",     "sendemail-validate",    "fsmonitor-watchman", "post-index-change",
};

/// Options that stop Git from running `core.fsmonitor` or any hook, whether
/// the hooks directory or config defines it.
pub const hardened_options = hardened: {
    var options: []const []const u8 = &.{
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
    };
    for (hook_events) |event| {
        options = options ++ [_][]const u8{ "-c", "hook." ++ event ++ ".enabled=false" };
    }

    break :hardened options[0..options.len].*;
};

/// No index write (so no `post-index-change`), no lazy fetch (Git 2.45 and
/// later) and no credential prompt.
const hardened_environment = [_][2][]const u8{
    .{ "GIT_OPTIONAL_LOCKS", "0" },
    .{ "GIT_NO_LAZY_FETCH", "1" },
    .{ "GIT_TERMINAL_PROMPT", "0" },
};

/// The first Git that honours `GIT_NO_LAZY_FETCH`; an older one would fetch
/// for a partial clone.
const lazy_fetch_switch: std.SemanticVersion = .{ .major = 2, .minor = 45, .patch = 0 };

const filter_keys = [_][]const u8{ "clean", "smudge", "process" };

/// Runs one read-only Git command with every repository-chosen program
/// turned off and returns what it printed, bounded as `request.stdout`
/// says. Standard error is read and dropped. `error.GitTimedOut` when Git
/// ran past `request.timeout`, including while reading the repository's
/// config; `error.GitFailed` when it failed or the repository cannot be read
/// safely.
///
/// ```zig
/// const output = untrusted_git.run(io, .{ .environ = environ, .path = path, .arguments = &.{ "status", "--porcelain" }, .timeout = timeout, .stdout = .{ .fail_past = 4096 } }) catch return null;
/// defer output.deinit();
/// ```
pub fn run(io: std.Io, request: GitRequest) RunError!GitOutput {
    var command: HardenedCommand = undefined;
    try command.prepare(io, request);
    defer command.deinit();

    const output = try collect(io, command.argvSlice(), &command.environ_map, .{
        .stdout = request.stdout,
        .stderr = .{ .keep_tail = 0 },
        .timeout = request.timeout,
    });
    if (!output.succeeded()) {
        output.deinit(std.heap.page_allocator);
        return error.GitFailed;
    }

    std.heap.page_allocator.free(output.stderr.bytes);
    return .{
        .stdout = output.stdout.bytes,
        .dropped = output.stdout.dropped,
    };
}

// Runs one Git child to its end within `bounds`, on the page allocator
// `GitOutput` frees with.
fn collect(io: std.Io, argv: []const []const u8, environ_map: *const std.process.Environ.Map, bounds: ChildOutput.Bounds) RunError!ChildOutput {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = environ_map,
    }) catch return error.GitFailed;
    defer child.kill(io);

    return ChildOutput.collect(std.heap.page_allocator, io, &child, bounds) catch |err| switch (err) {
        error.Timeout => error.GitTimedOut,
        else => error.GitFailed,
    };
}

/// Starts one read-only Git command, hardened as `run` does, with its
/// output on a pipe for a caller that streams it; the caller waits for or
/// kills the child. `request.timeout` bounds only the config read before
/// it; `request.stdout` is unused.
///
/// ```zig
/// var child = untrusted_git.spawn(io, .{ .environ = environ, .path = root, .arguments = &.{ "ls-files", "-z" }, .timeout = timeout }) orelse return;
/// defer child.kill(io);
/// ```
pub fn spawn(io: std.Io, request: GitRequest) ?std.process.Child {
    var command: HardenedCommand = undefined;
    command.prepare(io, request) catch return null;
    defer command.deinit();

    return std.process.spawn(io, .{
        .argv = command.argvSlice(),
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .environ_map = &command.environ_map,
    }) catch null;
}

/// The argv and environment of one hardened Git command; both live until
/// `deinit`, after the child started.
const HardenedCommand = struct {
    environ_map: std.process.Environ.Map,
    arena_state: std.heap.ArenaAllocator,
    argv: [max_arguments][]const u8,
    len: usize,

    fn prepare(self: *HardenedCommand, io: std.Io, request: GitRequest) RunError!void {
        const gpa = std.heap.page_allocator;
        self.environ_map = request.environ.createMap(gpa) catch return error.GitFailed;
        self.arena_state = .init(gpa);
        self.len = 0;
        errdefer self.deinit();

        removeGitVariables(&self.environ_map) catch return error.GitFailed;
        for (hardened_environment) |entry| {
            self.environ_map.put(entry[0], entry[1]) catch return error.GitFailed;
        }

        var facts: RepositoryFacts = .{};
        try readRepositoryFacts(io, request, &self.environ_map, self.arena_state.allocator(), &facts);
        if (facts.fetchesLazily() and !try lazyFetchSwitchable(io, request, &self.environ_map)) {
            return error.GitFailed;
        }

        self.push("git");
        for (hardened_options) |option| {
            self.push(option);
        }

        // An empty command turns the driver off; Git then compares raw content.
        for (facts.drivers[0..facts.driver_count]) |driver| {
            for (filter_keys) |key| {
                self.push("-c");
                self.push(std.fmt.allocPrint(self.arena_state.allocator(), "filter.{s}.{s}=", .{ driver, key }) catch return error.GitFailed);
            }
        }

        if (self.len + 2 + request.arguments.len > self.argv.len) {
            return error.GitFailed;
        }

        self.push("-C");
        self.push(request.path);
        for (request.arguments) |argument| {
            self.push(argument);
        }
    }

    fn push(self: *HardenedCommand, argument: []const u8) void {
        self.argv[self.len] = argument;
        self.len += 1;
    }

    fn argvSlice(self: *const HardenedCommand) []const []const u8 {
        return self.argv[0..self.len];
    }

    fn deinit(self: *HardenedCommand) void {
        self.environ_map.deinit();
        self.arena_state.deinit();
    }
};

/// What the repository's own config makes Git do on its own: the filter
/// drivers it defines, whether it is a partial clone (`promisor`, a
/// `partialclonefilter` alone, or `extensions.partialClone`), and whether
/// it names the upload-pack a fetch would run.
const RepositoryFacts = struct {
    drivers: [max_filter_drivers][]const u8 = undefined,
    driver_count: usize = 0,
    partial_clone: bool = false,
    local_upload_pack: bool = false,

    /// Whether a Git that cannot switch lazy fetching off could run a
    /// program for this repository while reading it.
    fn fetchesLazily(self: *const RepositoryFacts) bool {
        return self.partial_clone or self.local_upload_pack;
    }
};

/// Reads the repository's own config (local and worktree scope, including
/// the files it includes); the user's global and system config, such as a
/// Git LFS driver, stays trusted. Reading config runs no program. Fails
/// when there are too many drivers or a name `-c` cannot carry. Driver
/// names are copied into `arena`.
fn readRepositoryFacts(io: std.Io, request: GitRequest, environ_map: *const std.process.Environ.Map, arena: std.mem.Allocator, facts: *RepositoryFacts) RunError!void {
    const pattern = "^(filter\\.|extensions\\.partialclone$|remote\\..*\\.(promisor|partialclonefilter|uploadpack)$)";
    const argv = [_][]const u8{"git"} ++ hardened_options ++ [_][]const u8{ "-C", request.path, "config", "--show-scope", "-z", "--get-regexp", pattern };
    const output = try collect(io, &argv, environ_map, .{
        .stdout = .{ .fail_past = max_config_bytes },
        .stderr = .{ .keep_tail = 0 },
        .timeout = request.timeout,
    });
    defer output.deinit(std.heap.page_allocator);
    if (output.term != .exited) {
        return error.GitFailed;
    }

    // `git config --get-regexp` exits 1 when nothing matches.
    switch (output.term.exited) {
        0 => {},
        1 => return,
        else => return error.GitFailed,
    }

    parseFacts(output.stdout.bytes, facts) orelse return error.GitFailed;
    for (facts.drivers[0..facts.driver_count]) |*driver| {
        driver.* = arena.dupe(u8, driver.*) catch return error.GitFailed;
    }
}

/// Reads `scope\0key\nvalue\0` records. Driver names borrow `listing`.
fn parseFacts(listing: []const u8, facts: *RepositoryFacts) ?void {
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
        if (std.mem.eql(u8, key, "extensions.partialclone")) {
            facts.partial_clone = true;
            continue;
        }

        // Presence alone counts, whatever the value: Git reads any non-zero
        // integer (`2`, `1k`) as true, and an empty filter still makes its
        // remote a promisor.
        const promisor = std.mem.endsWith(u8, key, ".promisor") or std.mem.endsWith(u8, key, ".partialclonefilter");
        if (std.mem.startsWith(u8, key, "remote.") and promisor) {
            facts.partial_clone = true;
            continue;
        }

        if (std.mem.startsWith(u8, key, "remote.") and std.mem.endsWith(u8, key, ".uploadpack")) {
            facts.local_upload_pack = true;
            continue;
        }

        addDriver(key, facts) orelse return null;
    }
}

/// Records the driver a `filter.<name>.<key>` names; `[filter ""]` is one
/// too, reached by the attribute `filter=`.
fn addDriver(key: []const u8, facts: *RepositoryFacts) ?void {
    const prefix = "filter.";
    const variable_start = std.mem.lastIndexOfScalar(u8, key, '.') orelse return null;
    if (!std.mem.startsWith(u8, key, prefix) or variable_start < prefix.len) {
        return;
    }

    const name = key[prefix.len..variable_start];
    if (std.mem.indexOfAny(u8, name, "=\n\x00") != null) {
        return null;
    }

    for (facts.drivers[0..facts.driver_count]) |driver| {
        if (std.mem.eql(u8, driver, name)) {
            return;
        }
    }

    if (facts.driver_count == max_filter_drivers) {
        return null;
    }

    facts.drivers[facts.driver_count] = name;
    facts.driver_count += 1;
}

/// Whether this Git honours `GIT_NO_LAZY_FETCH`.
fn lazyFetchSwitchable(io: std.Io, request: GitRequest, environ_map: *const std.process.Environ.Map) RunError!bool {
    const output = collect(io, &.{ "git", "version" }, environ_map, .{
        .stdout = .{ .fail_past = max_version_bytes },
        .stderr = .{ .keep_tail = 0 },
        .timeout = request.timeout,
    }) catch |err| switch (err) {
        error.GitTimedOut => return err,
        error.GitFailed => return false,
    };
    defer output.deinit(std.heap.page_allocator);
    if (!output.succeeded()) {
        return false;
    }

    const version = parseVersion(output.stdout.bytes) orelse return false;
    return version.order(lazy_fetch_switch) != .lt;
}

/// Reads `git version 2.55.0` or `git version 2.39.5 (Apple Git-154)`.
fn parseVersion(output: []const u8) ?std.SemanticVersion {
    var words = std.mem.tokenizeAny(u8, output, " \r\n");
    if (!std.mem.eql(u8, words.next() orelse return null, "git") or !std.mem.eql(u8, words.next() orelse return null, "version")) {
        return null;
    }

    var numbers = std.mem.splitScalar(u8, words.next() orelse return null, '.');
    return .{
        .major = std.fmt.parseUnsigned(usize, numbers.next() orelse return null, 10) catch return null,
        .minor = std.fmt.parseUnsigned(usize, numbers.next() orelse return null, 10) catch return null,
        .patch = 0,
    };
}

/// Drops every `GIT_*` variable: `GIT_DIR`, `GIT_WORK_TREE`,
/// `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`, `GIT_CONFIG_*` and the rest
/// would point Git at another repository or feed it config.
fn removeGitVariables(environ_map: *std.process.Environ.Map) !void {
    var name_buffer: [256]u8 = undefined;
    var index: usize = 0;
    while (index < environ_map.count()) {
        const name = environ_map.keys()[index];
        if (!std.mem.startsWith(u8, name, "GIT_")) {
            index += 1;
            continue;
        }

        if (name.len > name_buffer.len) {
            return error.NameTooLong;
        }

        @memcpy(name_buffer[0..name.len], name);
        _ = environ_map.swapRemove(name_buffer[0..name.len]);
    }
}

test "the repository's own config names its drivers and whether it is a partial clone" {
    var facts: RepositoryFacts = .{};
    const listing = "local\x00filter.evil.clean\n/tmp/x\x00local\x00filter.evil.smudge\ncat\x00" ++
        "global\x00filter.lfs.clean\ngit-lfs clean -- %f\x00worktree\x00filter.sp ace.process\ny\x00" ++
        "local\x00filter..clean\n/tmp/unnamed\x00local\x00filter.clean\nignored\x00";
    parseFacts(listing, &facts).?;
    try std.testing.expectEqual(@as(usize, 3), facts.driver_count);
    try std.testing.expectEqualStrings("evil", facts.drivers[0]);
    try std.testing.expectEqualStrings("sp ace", facts.drivers[1]);
    try std.testing.expectEqualStrings("", facts.drivers[2]);
    try std.testing.expect(!facts.partial_clone);

    var partial: RepositoryFacts = .{};
    parseFacts("local\x00remote.origin.promisor\ntrue\x00", &partial).?;
    try std.testing.expect(partial.partial_clone);
    var extension: RepositoryFacts = .{};
    parseFacts("local\x00extensions.partialclone\norigin\x00", &extension).?;
    try std.testing.expect(extension.partial_clone);

    // A filter alone makes the remote a promisor Git fetches from lazily.
    var filtered: RepositoryFacts = .{};
    parseFacts("local\x00remote.origin.partialclonefilter\nblob:none\x00", &filtered).?;
    try std.testing.expect(filtered.partial_clone);

    // Git reads any non-zero integer, suffixed or not, as true, and an
    // empty filter still makes a promisor: presence alone counts.
    for ([_][]const u8{
        "local\x00remote.origin.partialclonefilter\n\x00",
        "local\x00remote.origin.promisor\n2\x00",
        "local\x00remote.origin.promisor\n1k\x00",
        "local\x00remote.origin.promisor\nfalse\x00",
    }) |present_listing| {
        var present: RepositoryFacts = .{};
        parseFacts(present_listing, &present).?;
        try std.testing.expect(present.partial_clone);
    }

    var upload: RepositoryFacts = .{};
    parseFacts("local\x00remote.origin.uploadpack\n/tmp/marker\x00", &upload).?;
    try std.testing.expect(upload.local_upload_pack and !upload.partial_clone);
    try std.testing.expect(upload.fetchesLazily());

    var global_upload: RepositoryFacts = .{};
    parseFacts("global\x00remote.origin.uploadpack\n/usr/bin/git-upload-pack\x00", &global_upload).?;
    try std.testing.expect(!global_upload.fetchesLazily());

    var empty: RepositoryFacts = .{};
    parseFacts("", &empty).?;
    try std.testing.expectEqual(@as(usize, 0), empty.driver_count);
    try std.testing.expect(parseFacts("local\x00filter.a=b.clean\nx\x00", &empty) == null);
}

test "Git versions before 2.45 cannot switch lazy fetching off" {
    try std.testing.expectEqual(std.math.Order.lt, parseVersion("git version 2.39.5 (Apple Git-154)\n").?.order(lazy_fetch_switch));
    try std.testing.expect(parseVersion("git version 2.55.0\n").?.order(lazy_fetch_switch) != .lt);
    try std.testing.expect(parseVersion("git version 2.45.0.windows.1\n").?.order(lazy_fetch_switch) != .lt);
    try std.testing.expect(parseVersion("hub version 2.14") == null);
}

test "every GIT_ variable leaves the environment Git gets" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("PATH", "/usr/bin");
    try environ_map.put("GIT_DIR", "/elsewhere/.git");
    try environ_map.put("HOME", "/home/me");
    try environ_map.put("GIT_CONFIG_COUNT", "1");
    try environ_map.put("GIT_WORK_TREE", "/elsewhere");

    try removeGitVariables(&environ_map);
    try std.testing.expectEqual(@as(usize, 2), environ_map.count());
    try std.testing.expect(environ_map.get("PATH") != null and environ_map.get("HOME") != null);
}

test "hooks are off for every event, whatever defines them" {
    for (hook_events) |event| {
        var option_buffer: [64]u8 = undefined;
        const option = try std.fmt.bufPrint(&option_buffer, "hook.{s}.enabled=false", .{event});
        const present = for (hardened_options) |candidate| {
            if (std.mem.eql(u8, candidate, option)) {
                break true;
            }
        } else false;
        try std.testing.expect(present);
    }
}
