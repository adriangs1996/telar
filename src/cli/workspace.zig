//! The `telar workspace` command family: create, list, inspect and rename
//! workspaces from the CLI. `create --worktree` is `telar worktree create`.

const std = @import("std");
const WorkspaceOptions = @import("arguments/WorkspaceOptions.zig");
const agent = @import("agent.zig");
const Session = @import("Session.zig");
const control = @import("control.zig");
const worktree = @import("worktree.zig");
const workspace_output = @import("workspace_output.zig");
const core = @import("telar-core");

/// The most words `create -- COMMAND` passes.
const max_command_words = 64;

/// Runs one workspace command and returns the process exit code.
///
/// ```zig
/// std.process.exit(try workspace.run(process_init, options));
/// ```
pub fn run(init: std.process.Init, options: WorkspaceOptions) !u8 {
    if (options.branch) |branch| {
        return worktree.run(init, .{
            .action = .create,
            .branch = branch,
            .title = options.name,
            .directory = options.directory,
            .socket = options.socket,
            .json = options.json,
        });
    }

    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    defer writer.flush() catch {};

    return execute(init, options, writer) catch |err| {
        std.debug.print("telar workspace: {s}\n", .{describe(err)});
        return agent.exit_failure;
    };
}

/// Asks the runtime to create a workspace rooted at an existing directory.
fn execute(init: std.process.Init, options: WorkspaceOptions, writer: *std.Io.Writer) !u8 {
    if (options.action == .list or options.action == .get) {
        return list(init, options, writer);
    }
    if (options.action == .rename) {
        return rename(init, options, writer);
    }

    var directory_buffer: [4096]u8 = undefined;
    const directory = try resolveDirectory(init, options, &directory_buffer);
    const default_name = std.fs.path.basename(directory);
    const name = if (options.name) |value| std.mem.span(value) else default_name;
    if (name.len == 0) {
        return error.MissingWorkspaceName;
    }

    var command_buffer: [max_command_words][]const u8 = undefined;
    if (options.command.len > command_buffer.len) {
        return error.WorkspaceCommandTooLong;
    }

    for (options.command, 0..) |word, index| {
        command_buffer[index] = std.mem.span(word);
    }

    const shell = [_][]const u8{shellArgument(init.minimal.environ)};
    var session = try Session.open(init, options.socket);
    defer session.close();
    const opened = try session.createWorkspace(.{
        .name = name,
        .cwd = directory,
        .arguments = if (options.command.len != 0) command_buffer[0..options.command.len] else &shell,
        .columns = options.columns orelse 80,
    });
    const workspace_id = core.raw(opened.location.workspace.workspace);

    if (options.json) {
        try writer.print("{{\"workspace_id\":{d},\"pane_id\":{d},\"directory\":", .{ workspace_id, core.raw(opened.pane_id) });
        try control.writeJsonString(writer, directory);
        try writer.writeAll("}\n");
    } else {
        try writer.print("workspace {d} created at {s}\n", .{ workspace_id, directory });
    }

    return agent.exit_ok;
}

fn rename(init: std.process.Init, options: WorkspaceOptions, writer: *std.Io.Writer) !u8 {
    const id = try options.target.?.resolve(init.minimal.environ, "TELAR_WORKSPACE_ID");
    var session = try Session.attach(init, options.socket);
    defer session.close();
    const response = try session.exchange(core.encodeRenameWorkspace, core.RenameWorkspace{
        .request_id = .none,
        .workspace = .{ .workspace = @enumFromInt(id) },
        .name = std.mem.span(options.name.?),
    });
    if (response != .workspace_snapshot) {
        return error.UnexpectedRuntimeResponse;
    }

    const snapshot = response.workspace_snapshot;
    if (snapshot.workspace != .workspace or core.raw(snapshot.workspace.workspace) != id) {
        return error.UnexpectedRuntimeResponse;
    }

    if (options.json) {
        try std.json.Stringify.value(.{ .workspace_id = id, .name = snapshot.name }, .{}, writer);
        try writer.writeByte('\n');
    } else {
        try writer.print("workspace {d} renamed to {s}\n", .{ id, snapshot.name });
    }

    return agent.exit_ok;
}

fn list(init: std.process.Init, options: WorkspaceOptions, writer: *std.Io.Writer) !u8 {
    const wanted: ?u64 = if (options.target) |target| try target.resolve(init.minimal.environ, "TELAR_WORKSPACE_ID") else null;
    var session = try Session.attach(init, options.socket);
    defer session.close();
    try session.subscribeRuntime();

    while (true) {
        const response = try session.receive();
        if (response != .workspace_list) {
            continue;
        }

        if (wanted) |id| {
            var entries = response.workspace_list.entries();
            while (try entries.next()) |entry| {
                if (core.raw(entry.workspace) != id) {
                    continue;
                }

                try workspace_output.write(writer, entry, options.json);
                if (options.json) {
                    try writer.writeByte('\n');
                }

                return agent.exit_ok;
            }

            return error.WorkspaceNotFound;
        }

        if (options.json) {
            try writer.writeByte('[');
        } else {
            try writer.writeAll("ID\tNAME\tDIRECTORY\tTABS\tBRANCH\tGIT\n");
        }

        var entries = response.workspace_list.entries();
        var first = true;
        while (try entries.next()) |entry| {
            if (options.json and !first) {
                try writer.writeByte(',');
            }

            try workspace_output.write(writer, entry, options.json);
            first = false;
        }

        if (options.json) {
            try writer.writeAll("]\n");
        }

        return agent.exit_ok;
    }
}

fn resolveDirectory(init: std.process.Init, options: WorkspaceOptions, buffer: []u8) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(init.io, std.mem.span(options.directory.?), .{});
    defer dir.close(init.io);
    const length = try dir.realPath(init.io, buffer);
    return buffer[0..length];
}

fn shellArgument(environ: std.process.Environ) []const u8 {
    const configured = environ.getPosix("SHELL") orelse return "/bin/sh";
    if (configured.len == 0) {
        return "/bin/sh";
    }

    return configured;
}

fn describe(err: anyerror) []const u8 {
    return control.describe(err);
}
