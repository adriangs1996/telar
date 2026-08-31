//! Live child-process and PTY ownership for one runtime pane.

const std = @import("std");
const command_mod = @import("command.zig");
const environment_mod = @import("environment.zig");
const exit_mod = @import("exit.zig");
const native = @import("native.zig");
const spawn_mod = @import("spawn.zig");

const Command = command_mod.Command;
const Environment = environment_mod.Environment;
const File = std.Io.File;

pub const Exit = exit_mod.Exit;

pub const Size = struct {
    cols: u16,
    rows: u16,
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,

    pub fn valid(size: Size) Size {
        return .{
            .cols = if (size.cols == 0) 80 else size.cols,
            .rows = if (size.rows == 0) 24 else size.rows,
            .cell_width_px = size.cell_width_px,
            .cell_height_px = size.cell_height_px,
        };
    }
};

/// The process and PTY master owned by one runtime pane.
pub const Session = struct {
    master: std.c.fd_t,
    pid: std.c.pid_t,
    reaped: std.atomic.Value(bool) = .init(false),
    deinitialized: std.atomic.Value(bool) = .init(false),
    lifecycle_mutex: std.c.pthread_mutex_t = .{},

    pub fn spawn(command: *const Command, initial_size: Size) !Session {
        var window = windowSize(initial_size);
        const spawned = try spawn_mod.spawn(command, &window);
        return .{ .master = spawned.master, .pid = spawned.pid };
    }

    pub fn file(session: *const Session) File {
        return .{
            .handle = session.master,
            .flags = .{ .nonblocking = false },
        };
    }

    /// Returns whether the session leader currently owns the terminal. A
    /// foreground job gets a different process group, regardless of shell.
    ///
    /// ```zig
    /// const shell_is_foreground = session.shellForeground() orelse false;
    /// ```
    pub fn shellForeground(session: *const Session) ?bool {
        if (session.master < 0) return null;
        const foreground = native.foregroundProcessGroup(session.master) orelse return null;
        return foreground == session.pid;
    }

    /// Returns the foreground process group controlling the slave side. The
    /// observation worker uses this constant-cost signal before inspecting
    /// any native process metadata.
    ///
    /// ```zig
    /// const process_group = session.foregroundProcessGroup() orelse return;
    /// ```
    pub fn foregroundProcessGroup(session: *const Session) ?std.c.pid_t {
        if (session.master < 0) return null;
        return native.foregroundProcessGroup(session.master);
    }

    /// Reads the session leader's cwd without asking the shell to publish it.
    ///
    /// ```zig
    /// const path = session.cwd(&buffer) orelse return;
    /// ```
    pub fn cwd(session: *const Session, buffer: []u8) ?[]const u8 {
        return native.processCwd(session.pid, buffer);
    }

    /// Resizing the master updates the kernel's PTY state and sends SIGWINCH
    /// to the foreground process group on the slave side.
    ///
    /// ```zig
    /// try session.resize(size);
    /// ```
    pub fn resize(session: *Session, next_size: Size) !void {
        var window = windowSize(next_size);
        try native.setWindowSize(session.master, &window);
    }

    pub fn wait(session: *Session) !Exit {
        if (session.deinitialized.load(.acquire)) {
            return error.ChildAlreadyReaped;
        }

        session.lockLifecycle();
        if (session.reaped.load(.acquire)) {
            session.unlockLifecycle();
            return error.ChildAlreadyReaped;
        }
        session.unlockLifecycle();

        // The blocking observation happens outside the mutex so shutdown can
        // still terminate a running child. Once the child is a zombie, wait
        // and shutdown serialize the decision to reap or signal it.
        try native.waitObserve(session.pid);

        session.lockLifecycle();
        defer session.unlockLifecycle();
        if (session.reaped.load(.acquire)) {
            return error.ChildAlreadyReaped;
        }

        session.reaped.store(true, .release);
        return native.waitPid(session.pid);
    }

    /// Make every blocking operation on the session able to finish.
    ///
    /// The runtime calls this before cancelling its actors: `waitpid` is a
    /// blocking libc call and cannot be cancelled by `Io.Select`, so the child
    /// has to be terminated before the actor waiting for it can be joined.
    ///
    /// Deliberately does NOT close the master. Child death releases a blocked
    /// master *read* (EOF), but a master *write* blocked on a full slave
    /// input queue survives it, and Darwin's close then waits behind that
    /// write forever. The write actor is released by Io cancellation instead,
    /// and the master closes in `deinit` once every actor has been joined.
    ///
    /// ```zig
    /// session.shutdown();
    /// ```
    pub fn shutdown(session: *Session) void {
        if (session.deinitialized.load(.acquire)) {
            return;
        }

        session.lockLifecycle();
        defer session.unlockLifecycle();

        if (!session.reaped.load(.acquire)) {
            native.terminate(session.pid);
        }
    }

    fn closeMaster(session: *Session) void {
        if (session.master >= 0) {
            // A master write blocked on a full slave input queue survives
            // even the child's death, and Darwin's close then waits behind
            // it forever. Flushing both queues wakes the writer first.
            native.flushPty(session.master);
            native.closeDescriptor(&session.master);
        }
    }

    fn lockLifecycle(session: *Session) void {
        const result = std.c.pthread_mutex_lock(&session.lifecycle_mutex);
        std.debug.assert(result == .SUCCESS);
    }

    fn unlockLifecycle(session: *Session) void {
        const result = std.c.pthread_mutex_unlock(&session.lifecycle_mutex);
        std.debug.assert(result == .SUCCESS);
    }

    pub fn deinit(session: *Session) void {
        if (session.deinitialized.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
            return;
        }

        session.closeMaster();

        session.lockLifecycle();
        if (!session.reaped.load(.acquire)) {
            native.terminate(session.pid);
            _ = native.waitPid(session.pid) catch {};
            session.reaped.store(true, .release);
        }
        session.unlockLifecycle();

        const result = std.c.pthread_mutex_destroy(&session.lifecycle_mutex);
        std.debug.assert(result == .SUCCESS);
    }
};

fn windowSize(requested: Size) std.posix.winsize {
    const size = requested.valid();
    return .{
        .row = size.rows,
        .col = size.cols,
        .xpixel = std.math.mul(u16, size.cols, size.cell_width_px) catch std.math.maxInt(u16),
        .ypixel = std.math.mul(u16, size.rows, size.cell_height_px) catch std.math.maxInt(u16),
    };
}

test "zero-sized hosts still create a valid terminal" {
    const size: Size = .{ .cols = 0, .rows = 0 };
    try std.testing.expectEqual(Size{ .cols = 80, .rows = 24 }, size.valid());
}

test "PTY child receives the explicit terminal environment" {
    var inherited_map = std.process.Environ.Map.init(std.testing.allocator);
    defer inherited_map.deinit();
    try inherited_map.put("PATH", "/bin:/usr/bin");
    try inherited_map.put("GHOSTTY_RESOURCES_DIR", "/Applications/Ghostty.app/Contents/Resources");
    const inherited_block = try inherited_map.createPosixBlock(std.testing.allocator, .{});
    defer inherited_block.deinit(std.testing.allocator);

    var environment = try Environment.init(std.testing.allocator, .{ .block = inherited_block }, "telar");
    defer environment.deinit();

    const args = [_][*:0]const u8{
        "sh",
        "-c",
        "printf '%s|%s|%s' \"$TERM\" \"$TERM_PROGRAM\" \"${GHOSTTY_RESOURCES_DIR-unset}\"",
    };
    var command = try Command.fromArgv(&args);
    command.environment = &environment;
    var session = try Session.spawn(&command, .{ .cols = 40, .rows = 5 });
    defer session.deinit();

    var output: [128]u8 = undefined;
    const len = try session.file().readStreaming(std.testing.io, &.{&output});
    try std.testing.expectEqual(Exit{ .exited = 0 }, try session.wait());
    try std.testing.expectEqualStrings("xterm-256color|telar|unset", output[0..len]);
}

test "spawn rejects an invalid working directory before forking" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(std.testing.io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing = try std.fmt.bufPrintZ(&path_buffer, "{s}/missing", .{directory_buffer[0..directory_len]});
    const args = [_][*:0]const u8{ "/bin/sh", "-c", "exit 0" };
    var command = try Command.fromArgv(&args);
    command.cwd = missing.ptr;

    try std.testing.expectError(error.InvalidWorkingDirectory, Session.spawn(&command, .{ .cols = 20, .rows = 5 }));
}

test "spawn rejects a missing executable before returning a session" {
    const args = [_][*:0]const u8{"/telar-test/missing-executable"};
    const command = try Command.fromArgv(&args);

    try std.testing.expectError(error.ExecutableNotFound, Session.spawn(&command, .{ .cols = 20, .rows = 5 }));
}

test "spawn rejects an executable without execute permission" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var file = try temp.dir.createFile(io, "not-executable", .{ .permissions = File.Permissions.fromMode(0o600) });
    try file.writeStreamingAll(io, "exit 0");
    file.close(io);

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/not-executable", .{directory_buffer[0..directory_len]});
    const args = [_][*:0]const u8{path.ptr};
    const command = try Command.fromArgv(&args);

    try std.testing.expectError(error.ExecutableAccessDenied, Session.spawn(&command, .{ .cols = 20, .rows = 5 }));
}

test "spawn preserves execvp shell fallback semantics" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var script = try temp.dir.createFile(io, "script", .{ .permissions = File.Permissions.fromMode(0o700) });
    try script.writeStreamingAll(io, "printf 'fallback-ok'");
    script.close(io);

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const script_path = try std.fmt.bufPrintZ(&path_buffer, "{s}/script", .{directory_buffer[0..directory_len]});
    const args = [_][*:0]const u8{script_path.ptr};
    const command = try Command.fromArgv(&args);
    var session = try Session.spawn(&command, .{ .cols = 20, .rows = 5 });
    defer session.deinit();

    var output: [32]u8 = undefined;
    const len = try session.file().readStreaming(io, &.{&output});

    try std.testing.expectEqualStrings("fallback-ok", output[0..len]);
    try std.testing.expectEqual(Exit{ .exited = 0 }, try session.wait());
}

test "spawn marks the retained PTY master close-on-exec" {
    const args = [_][*:0]const u8{ "/bin/sh", "-c", "exit 0" };
    const command = try Command.fromArgv(&args);
    var session = try Session.spawn(&command, .{ .cols = 20, .rows = 5 });
    defer session.deinit();

    const flags = std.c.fcntl(session.master, std.c.F.GETFD);

    try std.testing.expect(flags >= 0);
    try std.testing.expect(flags & std.posix.FD_CLOEXEC != 0);
    try std.testing.expectEqual(Exit{ .exited = 0 }, try session.wait());
}

test "wait reaps a real child once and shutdown after the reap is harmless" {
    const args = [_][*:0]const u8{ "/bin/sh", "-c", "exit 3" };
    const command = try Command.fromArgv(&args);
    var session = try Session.spawn(&command, .{ .cols = 20, .rows = 5 });
    const exit = try session.wait();
    try std.testing.expectEqual(Exit{ .exited = 3 }, exit);
    try std.testing.expectError(error.ChildAlreadyReaped, session.wait());
    session.shutdown();
    session.deinit();
}

test "shutdown and wait coordinate ownership of the child PID" {
    const WaitCapture = struct {
        session: *Session,
        started: std.atomic.Value(bool) = .init(false),
        result: ?Exit = null,
        failure: ?anyerror = null,

        fn run(capture: *@This()) void {
            capture.started.store(true, .release);
            capture.result = capture.session.wait() catch |err| {
                capture.failure = err;
                return;
            };
        }
    };

    const args = [_][*:0]const u8{ "/bin/sh", "-c", "exec sleep 60" };
    const command = try Command.fromArgv(&args);
    var session = try Session.spawn(&command, .{ .cols = 20, .rows = 5 });
    defer session.deinit();

    var capture: WaitCapture = .{ .session = &session };
    const thread = try std.Thread.spawn(.{}, WaitCapture.run, .{&capture});
    while (!capture.started.load(.acquire)) {
        std.atomic.spinLoopHint();
    }

    session.shutdown();
    thread.join();

    try std.testing.expectEqual(@as(?anyerror, null), capture.failure);
    try std.testing.expectEqual(Exit{ .signaled = .KILL }, capture.result.?);
}
