const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const TabOptions = @import("arguments/TabOptions.zig");
const TabControl = @import("TabControl.zig");
const control = @import("control.zig");
const login_shell = @import("login_shell.zig");
const WorktreeCatalog = @import("WorktreeCatalog.zig");

/// Size of a tab opened before any UI shows it; a UI resizes it on view.
const background_size: core.TerminalSize = .{ .cols = 160, .rows = 48 };

/// Queries the tabs of an explicit or inherited workspace. Example: `const status = tab.run(init, options);`
pub fn run(init: std.process.Init, options: TabOptions) u8 {
    const workspace = options.workspace.resolve(init.minimal.environ, "TELAR_WORKSPACE_ID") catch |err| return fail(err, null);
    var session = Session.attach(init, options.socket) catch |err| return fail(err, null);
    defer session.close();

    // The runtime's reason borrows the session, so it is printed before the
    // session closes.
    execute(init, &session, options, workspace) catch |err| return fail(err, session.failure_reason);
    return 0;
}

fn fail(err: anyerror, reason: ?[]const u8) u8 {
    std.debug.print("telar tab: {s}\n", .{reason orelse control.describe(err)});
    return if (err == error.RuntimeTimeout) 3 else 1;
}

fn execute(init: std.process.Init, session: *Session, options: TabOptions, workspace: u64) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;
    if (options.action == .create) {
        try openInBackground(init, session, options, workspace, writer);
        try writer.flush();
        return;
    }

    if (options.target) |target| {
        const tab_id = try target.resolve(init.minimal.environ, "TELAR_TAB_ID");
        var command: TabControl = .{
            .session = session,
            .writer = writer,
            .location = .{ .workspace = .{ .workspace = @enumFromInt(workspace) }, .tab_id = @enumFromInt(tab_id) },
            .options = options,
        };
        try command.execute();
        try writer.flush();
        return;
    }

    const response = try session.exchange(core.encodeRequestWorkspaceSnapshot, core.RequestWorkspaceSnapshot{
        .request_id = .none,
        .workspace = .{ .workspace = @enumFromInt(workspace) },
    });
    if (response != .workspace_snapshot) {
        return error.UnexpectedRuntimeResponse;
    }

    const snapshot = response.workspace_snapshot;
    if (snapshot.workspace != .workspace or core.raw(snapshot.workspace.workspace) != workspace) {
        return error.UnexpectedRuntimeResponse;
    }

    if (options.json) {
        try writer.writeByte('[');
    } else {
        try writer.writeAll("ID\tPOSITION\tPANES\tLABEL\n");
    }

    var tabs = snapshot.tabs();
    var first = true;
    while (try tabs.next()) |entry| {
        if (options.json) {
            if (!first) {
                try writer.writeByte(',');
            }

            try std.json.Stringify.value(.{ .workspace_id = workspace, .tab_id = core.raw(entry.tab_id), .position = entry.position, .pane_count = entry.pane_count, .label = entry.label }, .{}, writer);
        } else {
            try writer.print("{d}\t{d}\t{d}\t{s}\n", .{ core.raw(entry.tab_id), entry.position, entry.pane_count, entry.label });
        }

        first = false;
    }

    if (options.json) {
        try writer.writeAll("]\n");
    }

    try writer.flush();
}

/// Opens a tab running the user's shell in the workspace's directory, the
/// way a new pane starts, without any UI switching to it: the person keeps
/// the focus, so `pane send-keys` may type into the new pane at once.
fn openInBackground(init: std.process.Init, session: *Session, options: TabOptions, workspace: u64, writer: *std.Io.Writer) !void {
    var catalog: WorktreeCatalog = .init(init.gpa);
    defer catalog.deinit();
    try session.fetchCatalog(&catalog);
    const directory = (catalog.findWorkspace(workspace) orelse return error.WorkspaceNotFound).path;

    const opened = try session.launchTab(.{
        .request_id = .none,
        .workspace = try core.workspace(workspace),
        .label = if (options.label) |label| std.mem.span(label) else "",
        .size = background_size,
        .launch = .{
            .cwd = directory,
            .arguments = &.{login_shell.loginShell(init.minimal.environ)},
        },
    });

    if (options.json) {
        try std.json.Stringify.value(.{
            .workspace_id = workspace,
            .tab_id = core.raw(opened.location.tab_id),
            .pane_id = core.raw(opened.pane_id),
            .pane_generation = opened.pane_generation,
        }, .{}, writer);
        try writer.writeByte('\n');
    } else {
        try writer.print("tab {d} opened in workspace {d}: pane {d}\n", .{ core.raw(opened.location.tab_id), workspace, core.raw(opened.pane_id) });
    }
}
