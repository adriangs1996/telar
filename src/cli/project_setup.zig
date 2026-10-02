const std = @import("std");
const core = @import("telar-core");
const privatefile = @import("privatefile");
const Session = @import("Session.zig");
const execution = @import("execution.zig");
const file_transfer = @import("file_transfer.zig");
const ProjectOptions = @import("arguments/ProjectOptions.zig");
pub const max_recipe_bytes = 32 * 1024;
pub const wait_seconds = 600;
const Recipe = struct { version: u8, argv: []const []const u8 };

/// Executes the explicitly requested declared recipe. Example: `return project_setup.run(init, options);`.
pub fn run(init: std.process.Init, options: ProjectOptions) u8 {
    const id = prepare(init, options.cwd, true, options.detach, null) catch |err| {
        std.debug.print("telar project: {s}; inspect the execution output, supply missing tools/access on this destination, then explicitly retry project setup\n", .{@errorName(err)});
        return 1;
    };
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    std.json.Stringify.value(.{
        .execution_id = id,
        .environment = if (id == null) "not_declared" else if (options.detach) "running" else "ready",
        .ready = id != null and !options.detach,
    }, .{}, &writer.interface) catch return 1;
    writer.interface.writeByte('\n') catch return 1;
    writer.interface.flush() catch return 1;
    return 0;
}

/// Checks a worktree's declaration and gates task launch on successful setup.
/// Example: `try project_setup.prepare(init, worktree_path, options.setup, false, options.socket);`.
pub fn prepare(init: std.process.Init, cwd: []const u8, authorized: bool, detach: bool, socket: ?[*:0]const u8) !?u64 {
    const path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/.telar/setup.json", .{cwd});
    var parent = file_transfer.openParent(init.io, path) catch |err| {
        if (err == error.FileNotFound) {
            return null;
        }

        return err;
    };
    defer parent.close(init.io);
    const file = file_transfer.openRegular(parent, "setup.json") catch |err| {
        if (err == error.FileNotFound) {
            return null;
        }

        return err;
    };
    defer file.close(init.io);
    if (!authorized) {
        return error.ProjectSetupRequiresExplicitSetupFlag;
    }

    const inode = try privatefile.Inode.fromDescriptor(file.handle);
    if (inode.kind() != .regular or inode.owner != std.c.getuid() or inode.links != 1 or inode.size > max_recipe_bytes) {
        return error.InvalidProjectRecipe;
    }

    var reader = file.readerStreaming(init.io, &.{});
    const text = try reader.interface.allocRemaining(init.arena.allocator(), .limited(max_recipe_bytes));
    const recipe = try std.json.parseFromSliceLeaky(Recipe, init.arena.allocator(), text, .{});
    if (recipe.version != 1 or recipe.argv.len == 0 or recipe.argv.len > core.ExecutionRequest.max_arguments) {
        return error.InvalidProjectRecipe;
    }

    var session = try Session.open(init, socket);
    defer session.close();
    var id: u64 = 0;
    while (id == 0) {
        init.io.random(std.mem.asBytes(&id));
    }

    var operation: core.ExecutionRequest = .{ .action = .start, .execution_id = id, .cwd = cwd, .argument_count = @intCast(recipe.argv.len) };
    @memcpy(operation.arguments[0..recipe.argv.len], recipe.argv);
    std.debug.print("telar project: setup execution {d}; each explicit invocation repeats the recipe\n", .{id});
    var reply = try execution.exchange(&session, operation);
    if (detach) {
        return id;
    }

    operation.action = .status;
    operation.argument_count = 0;
    const started = session.nowMs();
    while (true) {
        if (operation.stdout_offset != reply.stdout_offset or operation.stderr_offset != reply.stderr_offset) {
            return error.SetupOutputRetentionExceeded;
        }

        try std.Io.File.stderr().writeStreamingAll(init.io, reply.stdout[0..reply.stdout_len]);
        try std.Io.File.stderr().writeStreamingAll(init.io, reply.stderr[0..reply.stderr_len]);
        operation.stdout_offset += reply.stdout_len;
        operation.stderr_offset += reply.stderr_len;
        if ((reply.state == .exited or reply.state == .failed) and operation.stdout_offset == reply.stdout_total and operation.stderr_offset == reply.stderr_total) {
            if (reply.state != .exited or reply.exit_code != 0) {
                return error.ProjectSetupFailed;
            }

            return id;
        }

        if (session.nowMs() - started >= wait_seconds * std.time.ms_per_s) {
            return error.SetupWaitTimedOutExecutionContinues;
        }

        session.sleepMs(10);
        reply = try execution.exchange(&session, operation);
    }
}
