//! Claude Code's `WorktreeCreate` and `WorktreeRemove` hooks, answered by
//! telar so an agent's own worktrees (`--worktree`, `EnterWorktree`,
//! `isolation: worktree`) land where telar puts every worktree and join its
//! fleet. `WorktreeCreate` replaces Claude Code's own `git worktree add`: it
//! prints the checkout's absolute path, or fails so Claude Code gets none.

const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const WorktreeCatalog = @import("WorktreeCatalog.zig");
const control = @import("control.zig");
const worktree_git = @import("worktree_git.zig");
const workspace_grammar = @import("arguments/workspace.zig");
const WorktreeHookInput = @import("WorktreeHookInput.zig");

/// Whether `event` is one of the worktree hooks this file answers.
///
/// ```zig
/// if (hook_worktree.handles(input.hook_event_name)) return hook_worktree.answer(init, input, socket);
/// ```
pub fn handles(event: []const u8) bool {
    return std.mem.eql(u8, event, "WorktreeCreate") or std.mem.eql(u8, event, "WorktreeRemove");
}

/// Answers one worktree hook. Creation prints the checkout path on stdout.
///
/// ```zig
/// try hook_worktree.answer(init, input, options.socket);
/// ```
pub fn answer(init: std.process.Init, input: WorktreeHookInput, socket: ?[*:0]const u8) !void {
    if (std.mem.eql(u8, input.hook_event_name, "WorktreeCreate")) {
        return create(init, input, socket);
    }

    return remove(init, input, socket);
}

fn create(init: std.process.Init, input: WorktreeHookInput, socket: ?[*:0]const u8) !void {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = if (input.cwd.len != 0) input.cwd else try processCwd(init, &cwd_buffer);
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try worktree_git.mainRoot(init, cwd, &root_buffer);
    var name_buffer: [workspace_grammar.max_worktree_branch_bytes]u8 = undefined;
    const branch = try branchName(input.name, &name_buffer);
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try worktree_git.deriveDirectory(root, branch, &directory_buffer);
    var base_buffer: [256]u8 = undefined;
    const base = try worktree_git.currentBranch(init, cwd, &base_buffer);
    // The runtime records the base whole; refuse one it cannot hold before
    // Git creates anything.
    try workspace_grammar.validateWorktreeBranch(base);

    try worktree_git.add(init, .{
        .root = root,
        .directory = directory,
        .branch = branch,
        .base = base,
    });
    register(init, .{
        .socket = socket,
        .directory = directory,
        .branch = branch,
        .base = base,
    }) catch |err| std.debug.print("telar hook: worktree created but not tracked: {s}\n", .{control.describe(err)});

    var output_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    try output.interface.print("{s}\n", .{directory});
    try output.interface.flush();
}

/// Removes the checkout Claude Code is done with, never forcing: Git refuses
/// one with local changes, which then stays for the user to review.
fn remove(init: std.process.Init, input: WorktreeHookInput, socket: ?[*:0]const u8) !void {
    if (input.worktree_path.len == 0 or !std.fs.path.isAbsolute(input.worktree_path)) {
        return error.InvalidWorktreePath;
    }

    if (insidePane(init.minimal.environ)) {
        forget(init, socket, input.worktree_path) catch {};
    }

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try worktree_git.mainRoot(init, input.worktree_path, &root_buffer);
    worktree_git.remove(init, root, input.worktree_path, false) catch {
        std.debug.print("telar hook: kept {s}; it has changes to review\n", .{input.worktree_path});
    };
}

const Registration = struct {
    socket: ?[*:0]const u8,
    directory: []const u8,
    branch: []const u8,
    base: []const u8,
};

/// Tracks the new worktree under the pane's workspace when the agent runs
/// inside telar; outside telar there is nothing to track.
fn register(init: std.process.Init, registration: Registration) !void {
    const environ = init.minimal.environ;
    if (!insidePane(environ)) {
        return;
    }

    const workspace_text = environ.getPosix("TELAR_WORKSPACE_ID") orelse return;
    const workspace = try core.workspace(std.fmt.parseUnsigned(u64, workspace_text, 10) catch return error.InvalidWorkspaceId);
    const pane = try core.pane(try control.currentPaneId(environ));
    var session = try Session.attach(init, registration.socket);
    defer session.close();
    _ = try session.registerWorktree(.{
        .request_id = .none,
        .source = workspace,
        .created_by = pane,
        .path = registration.directory,
        .branch = registration.branch,
        .base = registration.base,
    });
}

fn forget(init: std.process.Init, socket: ?[*:0]const u8, path: []const u8) !void {
    var catalog: WorktreeCatalog = .init(init.gpa);
    defer catalog.deinit();
    var session = try Session.attach(init, socket);
    defer session.close();
    try session.fetchCatalog(&catalog);
    for (catalog.worktrees.items) |*worktree| {
        if (std.mem.eql(u8, worktree.path, path)) {
            return session.forgetWorktree(worktree.id);
        }
    }
}

/// The branch a worktree name becomes: the name itself when Git accepts it,
/// else its safe characters with the rest turned into dashes.
fn branchName(name: []const u8, buffer: *[workspace_grammar.max_worktree_branch_bytes]u8) ![]const u8 {
    if (workspace_grammar.validateWorktreeBranch(name)) |_| {
        return name;
    } else |_| {}

    var len: usize = 0;
    for (name) |byte| {
        if (len == buffer.len) {
            break;
        }

        const safe = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '/';
        buffer[len] = if (safe) byte else '-';
        len += 1;
    }

    const trimmed = std.mem.trim(u8, buffer[0..len], "-./");
    try workspace_grammar.validateWorktreeBranch(trimmed);
    return trimmed;
}

fn insidePane(environ: std.process.Environ) bool {
    _ = control.currentPaneId(environ) catch return false;
    return true;
}

fn processCwd(init: std.process.Init, buffer: []u8) ![]const u8 {
    const len = try std.Io.Dir.cwd().realPath(init.io, buffer);
    return buffer[0..len];
}

test "worktree names become safe branches" {
    var buffer: [workspace_grammar.max_worktree_branch_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("fix-tabs", try branchName("fix-tabs", &buffer));
    try std.testing.expectEqualStrings("my-task-2", try branchName("my task:2", &buffer));
    try std.testing.expectError(error.InvalidWorktreeBranch, branchName("..", &buffer));
    try std.testing.expect(handles("WorktreeCreate") and handles("WorktreeRemove") and !handles("Stop"));
}
