//! The `telar worktree` command family: create a Git worktree and launch a
//! command in it, run more commands there, list the fleet with its agents,
//! open a worktree in a UI, show its diff and remove it. Git runs here, in
//! the CLI process; the runtime tracks worktrees and owns their panes.

const std = @import("std");
const core = @import("telar-core");
const WorktreeOptions = @import("arguments/WorktreeOptions.zig");
const Session = @import("Session.zig");
const Snapshot = @import("Snapshot.zig");
const ControlAgent = @import("ControlAgent.zig");
const WorktreeCatalog = @import("WorktreeCatalog.zig");
const agent = @import("agent.zig");
const control = @import("control.zig");
const worktree_git = @import("worktree_git.zig");
const ListedWorktree = @import("ListedWorktree.zig");
const CatalogWorktree = @import("CatalogWorktree.zig");
const machine_dispatch = @import("machine_dispatch.zig");
const worktree_dispatch = @import("worktree_dispatch.zig");
const workspace_grammar = @import("arguments/workspace.zig");

/// Size of a pane launched before any UI sized it; a UI resizes it on view.
const launch_size: core.TerminalSize = .{ .cols = 160, .rows = 48 };
const wait_poll_ms = 250;

/// Runs one worktree command and returns the process exit code.
///
/// ```zig
/// std.process.exit(try worktree.run(process_init, options));
/// ```
pub fn run(init: std.process.Init, options: WorktreeOptions) !u8 {
    var output_buffer: [16 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    defer writer.flush() catch {};

    return execute(init, options, writer) catch |err| {
        writer.flush() catch {};
        std.debug.print("telar worktree: {s}\n", .{describe(err)});
        return switch (err) {
            error.WorktreeNotFound, error.WorkspaceNotFound, error.WorktreeHasNoWorkspace => agent.exit_not_found,
            else => agent.exit_failure,
        };
    };
}

fn execute(init: std.process.Init, options: WorktreeOptions, writer: *std.Io.Writer) !u8 {
    if (options.machine) |label| {
        // The machine's own label runs here like any other create.
        switch (try machine_dispatch.resolve(init, std.mem.span(label))) {
            .remote => |profile| return switch (options.action) {
                .fetch => worktree_dispatch.fetch(init, options, profile, writer),
                else => worktree_dispatch.create(init, options, profile),
            },
            .local => if (options.action == .fetch) {
                return error.FetchNeedsAnotherMachine;
            },
        }
    }

    var catalog: WorktreeCatalog = .init(init.gpa);
    defer catalog.deinit();
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    var session = try Session.open(init, options.socket);
    defer session.close();
    try session.fetchCatalog(&catalog);

    const command: Command = .{
        .session = &session,
        .catalog = &catalog,
        .options = options,
        .writer = writer,
        .arena = arena.allocator(),
    };
    return switch (options.action) {
        .create => create(init, command),
        .exec => exec(init, command),
        .list => list(init, command),
        .open => open(init, command),
        .diff => diff(init, command),
        .remove => remove(init, command),
        .resolve => resolve(init, command),
        .fetch => error.FetchNeedsAnotherMachine,
    };
}

/// What every subcommand works with.
const Command = struct {
    session: *Session,
    catalog: *const WorktreeCatalog,
    options: WorktreeOptions,
    writer: *std.Io.Writer,
    /// Owns strings that outlive one helper, freed when the command ends.
    arena: std.mem.Allocator,
};

fn create(init: std.process.Init, command: Command) !u8 {
    const options = command.options;
    const branch = std.mem.span(options.branch.?);
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const origin_directory = try originDirectory(init, command, &directory_buffer);
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try worktree_git.mainRoot(init, origin_directory, &root_buffer);

    var checkout_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const checkout = if (options.directory) |directory| std.mem.span(directory) else try worktree_git.deriveDirectory(root, branch, &checkout_buffer);
    for (command.catalog.worktrees.items) |*existing| {
        if (std.mem.eql(u8, existing.path, checkout) or std.mem.eql(u8, existing.branch, branch)) {
            return error.WorktreeExists;
        }
    }

    var base_buffer: [256]u8 = undefined;
    const base = if (options.from) |from| std.mem.span(from) else try worktree_git.currentBranch(init, root, &base_buffer);
    // The runtime records the base whole; refuse one it cannot hold before
    // Git creates anything, and a worktree it has no row left for.
    workspace_grammar.validateWorktreeBranch(base) catch return error.UnusableBase;
    if (command.catalog.worktrees.items.len >= core.max_worktree_entries) {
        return error.WorktreeLimitReached;
    }

    const source = try sourceWorkspace(init, command, root);
    try worktree_git.add(init, .{
        .root = root,
        .directory = checkout,
        .branch = branch,
        .base = base,
    });

    var argv_storage: [WorktreeOptions.max_command_arguments][]const u8 = undefined;
    const argv = options.argv(&argv_storage);
    var brief_buffer: [core.max_worktree_brief_bytes]u8 = undefined;
    const registered = try command.session.registerWorktree(.{
        .request_id = .none,
        .source = try core.workspace(source),
        .created_by = currentPane(init.minimal.environ),
        .path = checkout,
        .branch = branch,
        .base = base,
        .title = if (options.title) |title| std.mem.span(title) else "",
        .brief = briefOf(argv, &brief_buffer),
        .dispatched_from = if (options.dispatched_from) |label| std.mem.span(label) else "",
    });

    const shell = [_][]const u8{shellArgument(init.minimal.environ)};
    const opened = try launch(command.session, .{
        .worktree = registered.worktree,
        .directory = checkout,
        .label = if (options.label) |label| std.mem.span(label) else "",
        .argv = if (argv.len == 0) &shell else argv,
    });

    try writeLaunch(command.writer, .{
        .worktree = registered.worktree,
        .path = checkout,
        .branch = branch,
        .base = base,
        .opened = opened,
    }, options.json);
    return agent.exit_ok;
}

fn exec(init: std.process.Init, command: Command) !u8 {
    const worktree = try findOrAdopt(init, command);
    var argv_storage: [WorktreeOptions.max_command_arguments][]const u8 = undefined;
    const opened = try launch(command.session, .{
        .worktree = worktree.id,
        .directory = worktree.path,
        .label = if (command.options.label) |label| std.mem.span(label) else "",
        .argv = command.options.argv(&argv_storage),
    });

    if (command.options.wait) {
        return waitForExit(command, opened);
    }

    try writeLaunch(command.writer, .{
        .worktree = worktree.id,
        .path = worktree.path,
        .branch = worktree.branch,
        .base = worktree.base,
        .opened = opened,
    }, command.options.json);
    return agent.exit_ok;
}

/// Polls the launched pane until its command exits, then prints its final
/// output and returns its exit status as this process's.
fn waitForExit(command: Command, opened: core.PaneOpened) !u8 {
    const pane: Session.PaneRef = .{ .pane_id = core.raw(opened.pane_id), .pane_generation = opened.pane_generation };
    const deadline = command.session.nowMs() + @as(i64, command.options.timeout_seconds) * std.time.ms_per_s;
    while (true) {
        const text = try command.session.readPane(pane, .{ .rows = core.max_pane_text_rows, .source = .recent });
        if (text.exit_code) |code| {
            const output = std.mem.trimEnd(u8, text.text, " \n");
            if (command.options.json) {
                try std.json.Stringify.value(.{
                    .pane_id = pane.pane_id,
                    .exit_code = code,
                    .truncated = text.truncated,
                    .output = output,
                }, .{}, command.writer);
                try command.writer.writeByte('\n');
            } else {
                try command.writer.print("{s}\n", .{output});
                if (text.truncated) {
                    std.debug.print("telar worktree: older rows were omitted\n", .{});
                }
            }

            return std.math.cast(u8, code) orelse agent.exit_failure;
        }

        if (command.session.nowMs() >= deadline) {
            std.debug.print("telar worktree: the command is still running after {d}s; pane {d}\n", .{ command.options.timeout_seconds, pane.pane_id });
            return agent.exit_timeout;
        }

        command.session.sleepMs(wait_poll_ms);
    }
}

fn list(init: std.process.Init, command: Command) !u8 {
    var agents_session = try Session.open(init, command.options.socket);
    defer agents_session.close();
    const snapshot = try init.gpa.create(Snapshot);
    defer init.gpa.destroy(snapshot);
    snapshot.* = .{};
    try agents_session.fetchAgents(snapshot);

    const wanted_source = try listedSource(command);
    const writer = command.writer;
    if (command.options.json) {
        try writer.writeByte('[');
    } else {
        try writer.writeAll("BRANCH\tTITLE\tSTATE\tAGENT\tDIFF\tCOMMAND\tPATH\n");
    }

    var first = true;
    for (command.catalog.worktrees.items) |*worktree| {
        if (wanted_source) |source| {
            if (worktree.source != source) {
                continue;
            }
        }

        if (command.options.json) {
            if (!first) {
                try writer.writeByte(',');
            }

            try writeWorktreeJson(writer, worktree, snapshot);
        } else {
            try writeWorktreeRow(writer, worktree, snapshot);
        }

        first = false;
    }

    var untracked_storage = UntrackedWorktrees.init(init.gpa);
    defer untracked_storage.deinit();
    const untracked = untrackedWorktrees(init, command, &untracked_storage) catch &.{};
    for (untracked) |listed| {
        if (command.options.json) {
            if (!first) {
                try writer.writeByte(',');
            }

            try writer.writeAll("{\"worktree_id\":null,\"branch\":");
            try control.writeJsonString(writer, listed.branch);
            try writer.writeAll(",\"path\":");
            try control.writeJsonString(writer, listed.path);
            try writer.writeAll(",\"origin\":\"untracked\",\"agents\":[]}");
        } else {
            try writer.print("{s}\t-\tuntracked\t-\t-\t-\t{s}\n", .{ listed.branch, listed.path });
        }

        first = false;
    }

    if (command.options.json) {
        try writer.writeAll("]\n");
    }

    return agent.exit_ok;
}

const UntrackedWorktrees = struct {
    gpa: std.mem.Allocator,
    bytes: []u8 = &.{},
    items: [max_untracked]ListedWorktree = undefined,
    count: usize = 0,

    const max_untracked = 64;

    fn init(gpa: std.mem.Allocator) UntrackedWorktrees {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *UntrackedWorktrees) void {
        self.gpa.free(self.bytes);
    }
};

/// The linked worktrees Git knows in the current directory's repository
/// that telar does not track: made by hand, or left from a lost runtime.
fn untrackedWorktrees(init: std.process.Init, command: Command, storage: *UntrackedWorktrees) ![]const ListedWorktree {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try realPath(init, ".", &cwd_buffer);
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try worktree_git.mainRoot(init, cwd, &root_buffer);
    storage.bytes = try worktree_git.listPorcelain(init, root);
    var listed = worktree_git.listed(storage.bytes);
    while (listed.next()) |entry| {
        if (storage.count == UntrackedWorktrees.max_untracked) {
            break;
        }

        const tracked = for (command.catalog.worktrees.items) |*worktree| {
            if (std.mem.eql(u8, worktree.path, entry.path)) {
                break true;
            }
        } else false;
        if (!tracked) {
            storage.items[storage.count] = entry;
            storage.count += 1;
        }
    }

    return storage.items[0..storage.count];
}

/// The tracked worktree a reference names; else a Git worktree of the
/// current repository with that branch, registered on the spot so it joins
/// the fleet.
fn findOrAdopt(init: std.process.Init, command: Command) !CatalogWorktree {
    const reference = std.mem.span(command.options.branch.?);
    if (try command.catalog.find(reference)) |worktree| {
        return worktree.*;
    }

    var storage = UntrackedWorktrees.init(init.gpa);
    defer storage.deinit();
    const untracked = untrackedWorktrees(init, command, &storage) catch return error.WorktreeNotFound;
    for (untracked) |listed| {
        if (!std.mem.eql(u8, listed.branch, reference)) {
            continue;
        }

        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root = try worktree_git.mainRoot(init, listed.path, &root_buffer);
        var base_buffer: [256]u8 = undefined;
        const current = worktree_git.currentBranch(init, root, &base_buffer) catch "";
        // Without a base the runtime's probe finds the main checkout's branch.
        const base = if (workspace_grammar.validateWorktreeBranch(current)) |_| current else |_| "";
        const source = try sourceWorkspace(init, command, root);
        const registered = try command.session.registerWorktree(.{
            .request_id = .none,
            .source = try core.workspace(source),
            .created_by = currentPane(init.minimal.environ),
            .path = listed.path,
            .branch = listed.branch,
            .base = base,
        });
        return .{
            .id = registered.worktree,
            .source = source,
            .workspace = null,
            .created_by = null,
            .origin = .telar,
            .state = .active,
            .path = try command.arena.dupe(u8, listed.path),
            .branch = try command.arena.dupe(u8, listed.branch),
            .base = try command.arena.dupe(u8, base),
            .title = "",
            .brief = "",
            .diff_added = 0,
            .diff_removed = 0,
            .diff_files = 0,
            .commits_ahead = 0,
            .command_label = "",
            .command_state = .none,
            .command_exit = 0,
        };
    }

    return error.WorktreeNotFound;
}

fn open(init: std.process.Init, command: Command) !u8 {
    _ = init;
    const worktree = try command.catalog.find(std.mem.span(command.options.branch.?)) orelse return error.WorktreeNotFound;
    const workspace_id = worktree.workspace orelse return error.WorktreeHasNoWorkspace;
    const discovered = try command.session.exchange(core.encodeQueryClients, core.QueryClients{ .request_id = .none });
    if (discovered != .client_list) {
        return error.UnexpectedRuntimeResponse;
    }

    const clients = discovered.client_list.entries[0..discovered.client_list.count];
    const route = try chooseClient(clients, command.options.client);
    var request: core.ClientCommand = .{
        .request_id = .none,
        .route = .{ .id = route.id, .generation = route.generation },
        .action = .workspace_select,
        .target_id = workspace_id,
        .value = 0,
    };
    try request.setText("");
    const received = try command.session.exchange(core.encodeRequestClientCommand, request);
    if (received != .client_command_result or received.client_command_result.status == .failed) {
        return error.ClientCommandFailed;
    }

    if (command.options.json) {
        try std.json.Stringify.value(.{ .worktree_id = core.raw(worktree.id), .workspace_id = workspace_id, .client_id = route.id }, .{}, command.writer);
        try command.writer.writeByte('\n');
    } else {
        try command.writer.print("opened {s} in client {d}\n", .{ worktree.branch, route.id });
    }

    return agent.exit_ok;
}

fn diff(init: std.process.Init, command: Command) !u8 {
    const worktree = try findOrAdopt(init, command);
    try command.writer.flush();
    try worktree_git.diff(init, .{
        .directory = worktree.path,
        .base = if (worktree.base.len != 0) worktree.base else "HEAD",
        .scope = if (command.options.uncommitted) .uncommitted else .branch,
        .stat = command.options.stat,
    });
    return agent.exit_ok;
}

fn remove(init: std.process.Init, command: Command) !u8 {
    const options = command.options;
    const worktree = try command.catalog.find(std.mem.span(options.branch.?)) orelse return error.WorktreeNotFound;
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = worktree_git.mainRoot(init, worktree.path, &root_buffer) catch null;
    const exists = root != null;
    if (exists and !options.force and try worktree_git.hasChanges(init, worktree.path)) {
        return error.WorktreeHasChanges;
    }

    if (options.force and !try confirm(init, "Remove the worktree and discard its local changes")) {
        return error.RemovalCancelled;
    }

    if (options.delete_branch and !try confirm(init, "Also delete its branch")) {
        return error.RemovalCancelled;
    }

    try command.session.forgetWorktree(worktree.id);
    if (root) |main_root| {
        try worktree_git.remove(init, main_root, worktree.path, options.force);
        if (options.delete_branch) {
            try worktree_git.deleteBranch(init, main_root, worktree.branch, options.force);
        }
    }

    if (options.json) {
        try std.json.Stringify.value(.{ .worktree_id = core.raw(worktree.id), .path = worktree.path, .branch_deleted = options.delete_branch }, .{}, command.writer);
        try command.writer.writeByte('\n');
    } else {
        try command.writer.print("removed {s} at {s}\n", .{ worktree.branch, worktree.path });
    }

    return agent.exit_ok;
}

/// `telar worktree resolve --repository IDENTITY`: the main checkout of the
/// one project among this runtime's workspaces whose origin has that
/// identity. Another machine asks this before it pushes a branch here.
fn resolve(init: std.process.Init, command: Command) !u8 {
    const wanted = std.mem.span(command.options.repository.?);
    var found_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var found: ?[]const u8 = null;
    if (command.options.workspace != null) {
        var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory = try originDirectory(init, command, &directory_buffer);
        found = try matchingRoot(init, directory, wanted, &found_buffer) orelse return error.RepositoryNotInWorkspace;
    } else {
        for (command.catalog.workspaces.items) |*workspace| {
            var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const root = matchingRoot(init, workspace.path, wanted, &root_buffer) catch null orelse continue;
            if (found) |previous| {
                if (!std.mem.eql(u8, previous, root)) {
                    return error.AmbiguousRepository;
                }

                continue;
            }

            found = try copyInto(&found_buffer, root);
        }
    }

    const path = found orelse return error.RepositoryNotFound;
    if (command.options.json) {
        try std.json.Stringify.value(.{
            .repository = wanted,
            .path = path,
        }, .{}, command.writer);
        try command.writer.writeByte('\n');
    } else {
        try command.writer.print("{s}\n", .{path});
    }

    return agent.exit_ok;
}

/// The main checkout `directory` belongs to, when its origin has the
/// identity `wanted`.
fn matchingRoot(init: std.process.Init, directory: []const u8, wanted: []const u8, buffer: []u8) !?[]const u8 {
    const root = try worktree_git.mainRoot(init, directory, buffer);
    var identity_buffer: [WorktreeOptions.max_repository_bytes]u8 = undefined;
    const identity = try worktree_git.originIdentity(init, root, &identity_buffer);
    return if (std.mem.eql(u8, identity, wanted)) root else null;
}

/// The directory whose repository a new worktree comes from: `--workspace`
/// (an id or a directory), else the calling pane's workspace, else the
/// current directory.
fn originDirectory(init: std.process.Init, command: Command, buffer: []u8) ![]const u8 {
    if (command.options.workspace) |value| {
        const text = std.mem.span(value);
        if (std.fmt.parseUnsigned(u64, text, 10)) |id| {
            const workspace = command.catalog.findWorkspace(id) orelse return error.WorkspaceNotFound;
            return copyInto(buffer, workspace.path);
        } else |_| {
            return realPath(init, text, buffer);
        }
    }

    if (currentWorkspace(init.minimal.environ)) |id| {
        if (command.catalog.findWorkspace(id)) |workspace| {
            return copyInto(buffer, workspace.path);
        }
    }

    return realPath(init, ".", buffer);
}

/// The workspace a new worktree hangs from: an explicit id, else the calling
/// pane's workspace when it belongs to the same repository, else the
/// workspace rooted at the repository, created when none exists.
fn sourceWorkspace(init: std.process.Init, command: Command, root: []const u8) !u64 {
    if (command.options.workspace) |value| {
        if (std.fmt.parseUnsigned(u64, std.mem.span(value), 10)) |id| {
            return id;
        } else |_| {}
    }

    if (currentWorkspace(init.minimal.environ)) |id| {
        if (command.catalog.findWorkspace(id)) |workspace| {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const workspace_root = worktree_git.mainRoot(init, workspace.path, &buffer) catch "";
            if (std.mem.eql(u8, workspace_root, root)) {
                return id;
            }
        }
    }

    if (command.catalog.workspaceAt(root)) |workspace| {
        return workspace.id;
    }

    var creator = try Session.open(init, command.options.socket);
    defer creator.close();
    const opened = try creator.createWorkspace(.{
        .name = std.fs.path.basename(root),
        .cwd = root,
        .arguments = &.{shellArgument(init.minimal.environ)},
    });
    return core.raw(opened.location.workspace.workspace);
}

/// The workspace whose worktrees `list` shows: all without `--workspace`.
fn listedSource(command: Command) !?u64 {
    const value = command.options.workspace orelse return null;
    const text = std.mem.span(value);
    if (std.fmt.parseUnsigned(u64, text, 10)) |id| {
        return id;
    } else |_| {
        const workspace = command.catalog.workspaceAt(text) orelse return error.WorkspaceNotFound;
        return workspace.id;
    }
}

const LaunchRequest = struct {
    worktree: core.WorktreeId,
    directory: []const u8,
    label: []const u8,
    argv: []const []const u8,
};

fn launch(session: *Session, request: LaunchRequest) !core.PaneOpened {
    return session.launchWorktree(.{
        .request_id = .none,
        .worktree = request.worktree,
        .label = request.label,
        .size = launch_size,
        .launch = .{
            .cwd = request.directory,
            .arguments = request.argv,
        },
    });
}

const Launched = struct {
    worktree: core.WorktreeId,
    path: []const u8,
    branch: []const u8,
    base: []const u8,
    opened: core.PaneOpened,
};

fn writeLaunch(writer: *std.Io.Writer, launched: Launched, json: bool) !void {
    const workspace_id = core.raw(launched.opened.location.workspace.workspace);
    if (json) {
        try std.json.Stringify.value(.{
            .worktree_id = core.raw(launched.worktree),
            .branch = launched.branch,
            .base = launched.base,
            .path = launched.path,
            .workspace_id = workspace_id,
            .tab_id = core.raw(launched.opened.location.tab_id),
            .pane_id = core.raw(launched.opened.pane_id),
            .pane_generation = launched.opened.pane_generation,
        }, .{}, writer);
        try writer.writeByte('\n');
        return;
    }

    try writer.print("worktree {s} at {s}: pane {d} in workspace {d}\n", .{
        launched.branch,
        launched.path,
        core.raw(launched.opened.pane_id),
        workspace_id,
    });
}

fn writeWorktreeJson(writer: *std.Io.Writer, worktree: *const CatalogWorktree, snapshot: *const Snapshot) !void {
    try writer.print("{{\"worktree_id\":{d},\"branch\":", .{core.raw(worktree.id)});
    try control.writeJsonString(writer, worktree.branch);
    try writer.writeAll(",\"title\":");
    try control.writeJsonString(writer, worktree.title);
    try writer.writeAll(",\"brief\":");
    try control.writeJsonString(writer, worktree.brief);
    try writer.writeAll(",\"base\":");
    try control.writeJsonString(writer, worktree.base);
    try writer.writeAll(",\"dispatched_from\":");
    try control.writeJsonString(writer, worktree.dispatched_from);
    try writer.writeAll(",\"path\":");
    try control.writeJsonString(writer, worktree.path);
    try writer.print(",\"origin\":\"{s}\",\"state\":\"{s}\",\"source_workspace_id\":{d},\"workspace_id\":", .{
        @tagName(worktree.origin),
        @tagName(worktree.state),
        worktree.source,
    });
    if (worktree.workspace) |id| {
        try writer.print("{d}", .{id});
    } else {
        try writer.writeAll("null");
    }

    try writer.print(",\"diff\":{{\"added\":{d},\"removed\":{d},\"files\":{d},\"commits_ahead\":{d}}},\"command\":{{\"label\":", .{
        worktree.diff_added,
        worktree.diff_removed,
        worktree.diff_files,
        worktree.commits_ahead,
    });
    try control.writeJsonString(writer, worktree.command_label);
    try writer.print(",\"state\":\"{s}\",\"exit_code\":{d}}},\"agents\":[", .{ @tagName(worktree.command_state), worktree.command_exit });
    var first = true;
    for (snapshot.slice()) |*member| {
        if (member.work_tree != core.raw(worktree.id)) {
            continue;
        }

        if (!first) {
            try writer.writeByte(',');
        }

        try control.writeAgentJson(writer, member);
        first = false;
    }

    try writer.writeAll("]}");
}

fn writeWorktreeRow(writer: *std.Io.Writer, worktree: *const CatalogWorktree, snapshot: *const Snapshot) !void {
    var status: []const u8 = "-";
    for (snapshot.slice()) |*member| {
        if (member.work_tree == core.raw(worktree.id)) {
            status = control.statusName(member.status);
            break;
        }
    }

    try writer.print("{s}\t{s}\t{s}\t{s}\t+{d} -{d} {d} files\t{s} {s}\t{s}\n", .{
        worktree.branch,
        worktree.displayName(),
        @tagName(worktree.state),
        status,
        worktree.diff_added,
        worktree.diff_removed,
        worktree.diff_files,
        if (worktree.command_label.len != 0) worktree.command_label else "-",
        @tagName(worktree.command_state),
        worktree.path,
    });
}

/// The explicit client, else the UI a person used last.
fn chooseClient(clients: []const core.ClientDescriptor, wanted: u64) !core.ClientDescriptor {
    var chosen: ?core.ClientDescriptor = null;
    for (clients) |client| {
        if (wanted != 0) {
            if (client.id == wanted) {
                return client;
            }

            continue;
        }

        if (chosen == null or client.last_input_sequence > chosen.?.last_input_sequence) {
            chosen = client;
        }
    }

    return chosen orelse error.ClientNotFound;
}

/// Asks on the controlling terminal. Without one, as when an agent runs the
/// command, the answer is no: destructive removals belong to a person.
fn confirm(init: std.process.Init, question: []const u8) !bool {
    const stdin = std.Io.File.stdin();
    if (!(stdin.isTty(init.io) catch false)) {
        return error.ConfirmationNeedsTerminal;
    }

    std.debug.print("{s}? [y/N] ", .{question});
    var buffer: [16]u8 = undefined;
    var reader = stdin.readerStreaming(init.io, &buffer);
    const line = reader.interface.takeDelimiterExclusive('\n') catch return false;
    const answer = std.mem.trim(u8, line, " \r\t");
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

/// The command's arguments after the program, joined by spaces: usually the
/// prompt an agent starts with. Control bytes other than newline and tab are
/// dropped and the result is cut on a UTF-8 boundary.
fn briefOf(argv: []const []const u8, buffer: *[core.max_worktree_brief_bytes]u8) []const u8 {
    if (argv.len < 2) {
        return "";
    }

    var len: usize = 0;
    for (argv[1..], 0..) |argument, index| {
        if (index != 0 and len < buffer.len) {
            buffer[len] = ' ';
            len += 1;
        }

        for (argument) |byte| {
            if (len == buffer.len) {
                break;
            }

            const control_byte = (byte < 0x20 and byte != '\n' and byte != '\t') or byte == 0x7f;
            if (!control_byte) {
                buffer[len] = byte;
                len += 1;
            }
        }
    }

    while (len > 0 and !std.unicode.utf8ValidateSlice(buffer[0..len])) {
        len -= 1;
    }

    return buffer[0..len];
}

fn currentPane(environ: std.process.Environ) ?core.PaneId {
    const id = control.currentPaneId(environ) catch return null;
    return core.pane(id) catch null;
}

fn currentWorkspace(environ: std.process.Environ) ?u64 {
    const value = environ.getPosix("TELAR_WORKSPACE_ID") orelse return null;
    const id = std.fmt.parseUnsigned(u64, value, 10) catch return null;
    return if (id == 0) null else id;
}

fn realPath(init: std.process.Init, path: []const u8, buffer: []u8) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(init.io, path, .{});
    defer dir.close(init.io);
    const len = try dir.realPath(init.io, buffer);
    return buffer[0..len];
}

fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) {
        return error.PathTooLong;
    }

    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

fn shellArgument(environ: std.process.Environ) []const u8 {
    const configured = environ.getPosix("SHELL") orelse return "/bin/sh";
    return if (configured.len == 0) "/bin/sh" else configured;
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NotARepository => "not inside a git repository",
        error.InvalidRepository => "could not derive a worktree directory from the repository path",
        error.WorktreeAddFailed => "git worktree add failed",
        error.WorktreeRemoveFailed => "git worktree remove failed",
        error.BranchDeleteFailed => "git branch deletion failed; the branch may not be merged",
        error.WorktreeExists => "that worktree already exists; use `telar worktree exec` to run more there",
        error.WorktreeHasChanges => "the worktree has local changes; commit them or pass --force",
        error.WorktreeHasNoWorkspace => "nothing was launched in that worktree yet; use `telar worktree exec`",
        error.ConfirmationNeedsTerminal => "this removal needs a person to confirm it at a terminal",
        error.RemovalCancelled => "removal cancelled",
        error.ClientNotFound => "no UI client is attached; pass --client ID",
        error.ClientCommandFailed => "the UI client could not open the worktree",
        error.PathTooLong => "the worktree path exceeds the supported length",
        error.InvalidWorktreeBranch => "the branch name is not usable for a worktree",
        error.UnusableBase => "the base branch name is too long or not usable; pass --from REF",
        error.WorktreeLimitReached => "the runtime tracks as many worktrees as it can; remove one first",
        error.GitDiffFailed => "git diff failed",
        error.UnknownMachine => "no saved machine or local label has that name; see `telar machine list`",
        error.FetchNeedsAnotherMachine => "fetch brings a branch from another machine; this label names this one",
        error.NoOriginRemote => "the repository has no `origin` remote to find its clone by on the other machine",
        error.UnsupportedOrigin => "the `origin` remote is a local path, which names no clone on another machine",
        error.RepositoryNotFound => "no workspace on the machine holds this repository; open one there or pass --workspace PATH",
        error.RepositoryNotInWorkspace => "that workspace holds another repository",
        error.AmbiguousRepository => "several clones of this repository are open on the machine; pass --workspace PATH",
        error.UnexpectedResolveOutput => "the machine answered `worktree resolve` with something else; is its telar up to date?",
        error.MachineCommandFailed => "the command failed on the machine",
        error.UnknownRevision => "that revision names no commit here",
        error.GitPushFailed => "git push to the machine failed; a branch with other history there is never overwritten",
        error.GitFetchFailed => "git fetch from the machine failed",
        error.DestinationNotUsableByGit => "the machine's SSH destination has ':', '/' or brackets; save it as a host alias",
        error.UnquotableSshOption => "telar's runtime directory has a quote in its path, which git cannot be given safely",
        else => control.describe(err),
    };
}

test "the brief joins prompt arguments and drops control bytes" {
    var buffer: [core.max_worktree_brief_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("fix the\ttabs now", briefOf(&.{ "claude", "fix the\ttabs\x1b", "now" }, &buffer));
    try std.testing.expectEqualStrings("", briefOf(&.{"claude"}, &buffer));
}

test "the most recently used client wins unless one is named" {
    const clients = [_]core.ClientDescriptor{
        .{ .id = 1, .generation = 1, .identity = 5, .attachments = 1, .last_input_pane = 0, .last_input_sequence = 3 },
        .{ .id = 2, .generation = 1, .identity = 6, .attachments = 1, .last_input_pane = 0, .last_input_sequence = 9 },
    };
    try std.testing.expectEqual(@as(u64, 2), (try chooseClient(&clients, 0)).id);
    try std.testing.expectEqual(@as(u64, 1), (try chooseClient(&clients, 1)).id);
    try std.testing.expectError(error.ClientNotFound, chooseClient(&clients, 7));
}
