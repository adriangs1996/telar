//! Worktrees on another machine, from the machine that dispatches them.
//! `create --machine` finds the project's clone there, pushes the commit the
//! branch starts from, and asks that machine's telar to create the worktree;
//! `fetch --machine` brings the branch back into a remote-tracking ref. All
//! Git traffic starts here, over telar's managed SSH connection, so no
//! machine ever needs SSH back to this one.

const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const WorktreeOptions = @import("arguments/WorktreeOptions.zig");
const GitTransfer = @import("GitTransfer.zig");
const agent = @import("agent.zig");
const machine_dispatch = @import("machine_dispatch.zig");
const worktree_git = @import("worktree_git.zig");
const workspace_grammar = @import("arguments/workspace.zig");

const url_scheme = "ssh://";
/// Longest `ssh://DESTINATION/PATH` URL, in bytes.
const max_url_bytes = url_scheme.len + core.ssh_destination.max_bytes + std.fs.max_path_bytes;
/// Longest refspec, `+refs/heads/BRANCH:refs/remotes/LABEL/BRANCH`; a
/// pushed commit is shorter than a branch.
const max_refspec_bytes = "+refs/heads/:refs/remotes//".len + 2 * workspace_grammar.max_worktree_branch_bytes + core.MachineProfile.max_label_bytes;
/// Most words a forwarded `worktree create` carries besides the command.
const max_create_words = 16;
/// `telar worktree resolve --repository ID --json [--workspace PATH]`.
const max_resolve_words = 8;

/// Where the other machine keeps the project.
const RemoteClone = struct {
    profile: core.MachineProfile,
    /// The clone's main checkout there, owned by the caller's allocator.
    path: [:0]const u8,
};

/// `telar worktree create BRANCH --machine LABEL`: dispatches the worktree
/// and returns the exit status the other machine's `create` reported.
///
/// ```zig
/// return worktree_dispatch.create(init, options, profile);
/// ```
pub fn create(init: std.process.Init, options: WorktreeOptions, profile: core.MachineProfile) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const branch = std.mem.span(options.branch.?);
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try localRoot(init, &root_buffer);
    const clone = try findClone(init, .{
        .arena = arena,
        .root = root,
        .profile = profile,
        .workspace = options.workspace,
    });

    const continued = worktree_git.branchExists(init, root, branch);
    const source = if (continued) branch else if (options.from) |from| std.mem.span(from) else "HEAD";
    var commit_buffer: [worktree_git.max_commit_bytes]u8 = undefined;
    const commit = try worktree_git.commitOf(init, root, source, &commit_buffer);
    const left = worktree_git.changedFiles(init, root) catch 0;
    if (left != 0) {
        std.debug.print("telar worktree: {d} uncommitted files stay on this machine; only commits travel\n", .{left});
    }

    var refspec_buffer: [max_refspec_bytes]u8 = undefined;
    const refspec = try std.fmt.bufPrint(&refspec_buffer, "{s}:refs/heads/{s}", .{ commit, branch });
    try transfer(init, .{
        .root = root,
        .clone = &clone,
        .refspec = refspec,
        .direction = .push,
    });

    var label_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const local = try machine_dispatch.localLabel(init, &label_buffer);
    var words: [max_create_words + WorktreeOptions.max_command_arguments][*:0]const u8 = undefined;
    const argv = createArgv(.{
        .options = &options,
        .path = clone.path,
        .dispatched_from = try arena.dupeZ(u8, local),
        .base = if (continued) null else try arena.dupeZ(u8, commit),
    }, &words);
    return machine_dispatch.forward(init, &clone.profile, argv);
}

/// `telar worktree fetch BRANCH --machine LABEL`: updates
/// `refs/remotes/LABEL/BRANCH` from that machine's clone.
///
/// ```zig
/// return worktree_dispatch.fetch(init, options, profile, writer);
/// ```
pub fn fetch(init: std.process.Init, options: WorktreeOptions, profile: core.MachineProfile, writer: *std.Io.Writer) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const branch = std.mem.span(options.branch.?);
    const label = std.mem.span(options.machine.?);
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try localRoot(init, &root_buffer);
    const clone = try findClone(init, .{
        .arena = arena,
        .root = root,
        .profile = profile,
        .workspace = null,
    });

    var ref_buffer: [max_refspec_bytes]u8 = undefined;
    const ref = try std.fmt.bufPrint(&ref_buffer, "refs/remotes/{s}/{s}", .{ label, branch });
    var refspec_buffer: [max_refspec_bytes]u8 = undefined;
    const refspec = try std.fmt.bufPrint(&refspec_buffer, "+refs/heads/{s}:{s}", .{ branch, ref });
    try transfer(init, .{
        .root = root,
        .clone = &clone,
        .refspec = refspec,
        .direction = .fetch,
    });

    var commit_buffer: [worktree_git.max_commit_bytes]u8 = undefined;
    const commit = try worktree_git.commitOf(init, root, ref, &commit_buffer);
    if (options.json) {
        try std.json.Stringify.value(.{
            .machine = label,
            .branch = branch,
            .ref = ref,
            .commit = commit,
        }, .{}, writer);
        try writer.writeByte('\n');
    } else {
        try writer.print("fetched {s} from {s} into {s} at {s}\n", .{ branch, label, ref, commit });
    }

    return agent.exit_ok;
}

/// The main checkout of the repository the current directory is in.
fn localRoot(init: std.process.Init, buffer: []u8) ![]const u8 {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
    defer dir.close(init.io);
    const cwd = cwd_buffer[0..try dir.realPath(init.io, &cwd_buffer)];
    return worktree_git.mainRoot(init, cwd, buffer);
}

const CloneSearch = struct {
    arena: std.mem.Allocator,
    root: []const u8,
    profile: core.MachineProfile,
    /// The other machine's workspace to use when the identity alone is
    /// ambiguous there.
    workspace: ?[*:0]const u8,
};

/// Asks the other machine which of its workspaces holds this repository:
/// `telar worktree resolve --repository IDENTITY --json`.
fn findClone(init: std.process.Init, search: CloneSearch) !RemoteClone {
    var identity_buffer: [WorktreeOptions.max_repository_bytes]u8 = undefined;
    const identity = try worktree_git.originIdentity(init, search.root, &identity_buffer);
    const identity_z = try search.arena.dupeZ(u8, identity);

    var words: [max_resolve_words][*:0]const u8 = undefined;
    const required = [_][*:0]const u8{ "telar", "worktree", "resolve", "--repository", identity_z, "--json" };
    @memcpy(words[0..required.len], &required);
    var len: usize = required.len;
    if (search.workspace) |workspace| {
        words[len] = "--workspace";
        words[len + 1] = workspace;
        len += 2;
    }

    const output = try machine_dispatch.capture(init, &search.profile, words[0..len]);
    defer init.gpa.free(output);

    const parsed = std.json.parseFromSliceLeaky(Resolved, search.arena, output, .{
        .ignore_unknown_fields = true,
    }) catch return error.UnexpectedResolveOutput;
    if (!std.fs.path.isAbsolutePosix(parsed.path)) {
        return error.UnexpectedResolveOutput;
    }

    return .{
        .profile = search.profile,
        .path = try search.arena.dupeZ(u8, parsed.path),
    };
}

/// What `worktree resolve --json` prints.
const Resolved = struct {
    path: []const u8,
};

const Transfer = struct {
    root: []const u8,
    clone: *const RemoteClone,
    refspec: []const u8,
    direction: enum { push, fetch },
};

/// Runs one push or fetch against the other machine's clone, through the
/// same control master the dispatch uses.
fn transfer(init: std.process.Init, request: Transfer) !void {
    const destination = request.clone.profile.destination();
    if (std.mem.indexOfAny(u8, destination, ":/[]") != null) {
        return error.DestinationNotUsableByGit;
    }

    var url_buffer: [max_url_bytes]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, url_scheme ++ "{s}{s}", .{ destination, request.clone.path });
    const ssh = try client.SshOptions.prepare(init.io, init.minimal.environ, destination);
    var command_buffer: [std.fs.max_path_bytes + 512]u8 = undefined;
    var map = try init.minimal.environ.createMap(init.gpa);
    defer map.deinit();
    try map.put("GIT_SSH_COMMAND", try ssh.gitCommand(&command_buffer));
    try map.put("GIT_TERMINAL_PROMPT", "0");

    const git: GitTransfer = .{
        .root = request.root,
        .url = url,
        .refspec = request.refspec,
        .environ_map = &map,
    };
    return switch (request.direction) {
        .push => worktree_git.push(init, git),
        .fetch => worktree_git.fetch(init, git),
    };
}

const CreateWords = struct {
    options: *const WorktreeOptions,
    /// The clone on the other machine, passed as its `--workspace`.
    path: [:0]const u8,
    dispatched_from: [:0]const u8,
    /// The commit a new branch starts from, so its diff there shows only
    /// the task's work; null when an existing branch continues.
    base: ?[:0]const u8,
};

/// `telar worktree create BRANCH --workspace PATH --dispatched-from LABEL`
/// plus the options that apply there. The branch now exists on the other
/// machine, so `--from` there only records the commit it started from.
fn createArgv(request: CreateWords, words: [][*:0]const u8) []const [*:0]const u8 {
    const options = request.options;
    var len: usize = 0;
    for ([_][*:0]const u8{ "telar", "worktree", "create", options.branch.?, "--workspace", request.path, "--dispatched-from", request.dispatched_from }) |word| {
        words[len] = word;
        len += 1;
    }

    const optional = [_]struct { flag: [*:0]const u8, value: ?[*:0]const u8 }{
        .{ .flag = "--title", .value = options.title },
        .{ .flag = "--label", .value = options.label },
        .{ .flag = "--from", .value = if (request.base) |base| base.ptr else null },
    };
    for (optional) |pair| {
        if (pair.value) |value| {
            words[len] = pair.flag;
            words[len + 1] = value;
            len += 2;
        }
    }

    if (options.json) {
        words[len] = "--json";
        len += 1;
    }

    if (options.command_len != 0) {
        words[len] = "--";
        len += 1;
        for (options.command[0..options.command_len]) |argument| {
            words[len] = argument;
            len += 1;
        }
    }

    return words[0..len];
}

test "a dispatched create names the clone and this machine and keeps the command" {
    const options = try WorktreeOptions.parse(&.{ "create", "fix", "--machine", "box", "--from", "main", "--title", "Fix tabs", "--json", "--", "claude", "go" });
    var words: [max_create_words + WorktreeOptions.max_command_arguments][*:0]const u8 = undefined;
    const argv = createArgv(.{
        .options = &options,
        .path = "/home/dev/telar",
        .dispatched_from = "laptop",
        .base = "0123abc",
    }, &words);

    const expected = [_][]const u8{ "telar", "worktree", "create", "fix", "--workspace", "/home/dev/telar", "--dispatched-from", "laptop", "--title", "Fix tabs", "--from", "0123abc", "--json", "--", "claude", "go" };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| {
        try std.testing.expectEqualStrings(want, std.mem.span(got));
    }
}
