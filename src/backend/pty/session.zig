//! Live child-process and PTY ownership for one runtime pane.

const std = @import("std");
const command_mod = @import("command.zig");
const environment_mod = @import("environment.zig");
const exit_mod = @import("exit.zig");
const native = @import("native.zig");
const spawn_mod = @import("spawn.zig");

const Command = command_mod.Command;
const ChildEnvironment = environment_mod.ChildEnvironment;
const File = std.Io.File;

pub const Exit = exit_mod.Exit;

pub const Size = struct {
    cols: u16,
    rows: u16,
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,

    /// Replaces unusable zero cell dimensions with the terminal defaults.
    ///
    /// ```zig
    /// const size = requested.valid();
    /// ```
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
    wait_claimed: std.atomic.Value(bool) = .init(false),
    reaped: std.atomic.Value(bool) = .init(false),
    deinitialized: std.atomic.Value(bool) = .init(false),
    lifecycle_mutex: std.c.pthread_mutex_t = .{},

    /// Creates a PTY-backed child and returns only after `execve` succeeds.
    /// The command and its borrowed strings may be released after this call.
    ///
    /// ```zig
    /// var session = try Session.spawn(&command, .{ .cols = 80, .rows = 24 });
    /// defer session.deinit();
    /// ```
    pub fn spawn(command: *const Command, initial_size: Size) !Session {
        var window = windowSize(initial_size);
        const spawned = try spawn_mod.spawn(command, &window);
        return .{ .master = spawned.master, .pid = spawned.pid };
    }

    /// Returns the process identifier of the session leader.
    ///
    /// ```zig
    /// const pid = session.processId();
    /// ```
    pub fn processId(session: *const Session) std.c.pid_t {
        return session.pid;
    }

    /// Reads child output from the PTY master into the caller's buffer.
    ///
    /// ```zig
    /// const len = try session.read(io, &buffer);
    /// ```
    pub fn read(session: *const Session, io: std.Io, buffer: []u8) !usize {
        return session.file().readStreaming(io, &.{buffer});
    }

    /// Writes the complete input slice to the child through the PTY master.
    ///
    /// ```zig
    /// try session.writeAll(io, "git status\n");
    /// ```
    pub fn writeAll(session: *const Session, io: std.Io, bytes: []const u8) !void {
        return session.file().writeStreamingAll(io, bytes);
    }

    fn file(session: *const Session) File {
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
        if (session.master < 0) {
            return null;
        }

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
        if (session.master < 0) {
            return null;
        }

        return native.foregroundProcessGroup(session.master);
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

    /// Blocks until the child exits, reaps it exactly once, and returns its
    /// terminal status. One caller owns the wait. A concurrent call returns
    /// `ChildWaitAlreadyClaimed`; a later call returns `ChildAlreadyReaped`.
    ///
    /// ```zig
    /// const exit = try session.wait();
    /// ```
    pub fn wait(session: *Session) !Exit {
        if (session.deinitialized.load(.acquire)) {
            return error.ChildAlreadyReaped;
        }

        if (session.wait_claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
            if (session.reaped.load(.acquire)) {
                return error.ChildAlreadyReaped;
            }

            return error.ChildWaitAlreadyClaimed;
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

        const exit = try native.waitPid(session.pid);
        session.reaped.store(true, .release);
        return exit;
    }

    /// Makes every blocking operation on the session able to finish.
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

    /// Closes the PTY and reaps a child that was not already collected.
    /// Callers must first join operations using this session. Repeated calls
    /// are harmless.
    ///
    /// ```zig
    /// session.deinit();
    /// ```
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

const ReadExpectation = struct {
    buffer: []u8,
    suffix: []const u8,
};

fn readUntil(session: *const Session, io: std.Io, expectation: ReadExpectation) ![]const u8 {
    var len: usize = 0;
    while (!std.mem.endsWith(u8, expectation.buffer[0..len], expectation.suffix)) {
        if (len == expectation.buffer.len) {
            return error.UnexpectedPtyOutput;
        }

        const read_len = try session.read(io, expectation.buffer[len..]);
        if (read_len == 0) {
            return error.UnexpectedPtyEof;
        }

        len += read_len;
    }

    return expectation.buffer[0..len];
}

test "zero-sized hosts still create a valid terminal" {
    const size: Size = .{ .cols = 0, .rows = 0 };
    try std.testing.expectEqual(Size{ .cols = 80, .rows = 24 }, size.valid());
}

test "pixel dimensions saturate instead of overflowing the native window" {
    const window = windowSize(.{
        .cols = std.math.maxInt(u16),
        .rows = std.math.maxInt(u16),
        .cell_width_px = std.math.maxInt(u16),
        .cell_height_px = std.math.maxInt(u16),
    });

    try std.testing.expectEqual(std.math.maxInt(u16), window.xpixel);
    try std.testing.expectEqual(std.math.maxInt(u16), window.ypixel);
}

test "the public session protocol identifies and exchanges bytes with the child" {
    const io = std.testing.io;
    const args = [_][*:0]const u8{
        "/bin/sh",
        "-c",
        "stty -echo; printf 'ready\\n'; IFS= read -r line; printf 'reply:%s\\n' \"$line\"",
    };
    const command = try Command.fromArgv(&args);
    var session = try Session.spawn(&command, .{ .cols = 40, .rows = 5 });
    defer session.deinit();

    try std.testing.expect(session.processId() > 0);

    var ready_buffer: [32]u8 = undefined;
    const ready = try readUntil(&session, io, .{ .buffer = &ready_buffer, .suffix = "ready\r\n" });
    try std.testing.expectEqualStrings("ready\r\n", ready);

    try session.writeAll(io, "hello\n");

    var reply_buffer: [32]u8 = undefined;
    const reply = try readUntil(&session, io, .{ .buffer = &reply_buffer, .suffix = "reply:hello\r\n" });
    try std.testing.expectEqualStrings("reply:hello\r\n", reply);
    try std.testing.expectEqual(Exit{ .exited = 0 }, try session.wait());
}

test "resize changes the dimensions observed by the child" {
    const io = std.testing.io;
    const args = [_][*:0]const u8{
        "/bin/sh",
        "-c",
        "stty -echo; printf 'ready\\n'; IFS= read -r ignored; stty size",
    };
    const command = try Command.fromArgv(&args);
    var session = try Session.spawn(&command, .{ .cols = 20, .rows = 5 });
    defer session.deinit();

    var ready_buffer: [32]u8 = undefined;
    _ = try readUntil(&session, io, .{ .buffer = &ready_buffer, .suffix = "ready\r\n" });

    try session.resize(.{ .cols = 71, .rows = 13 });
    try session.writeAll(io, "continue\n");

    var size_buffer: [32]u8 = undefined;
    const size = try readUntil(&session, io, .{ .buffer = &size_buffer, .suffix = "13 71\r\n" });
    try std.testing.expectEqualStrings("13 71\r\n", size);
    try std.testing.expectEqual(Exit{ .exited = 0 }, try session.wait());
}

test "PTY child receives the explicit terminal environment" {
    var inherited_map = std.process.Environ.Map.init(std.testing.allocator);
    defer inherited_map.deinit();
    try inherited_map.put("PATH", "/bin:/usr/bin");
    try inherited_map.put("GHOSTTY_RESOURCES_DIR", "/Applications/Ghostty.app/Contents/Resources");
    const inherited_block = try inherited_map.createPosixBlock(std.testing.allocator, .{});
    defer inherited_block.deinit(std.testing.allocator);

    var environment = try ChildEnvironment.init(std.testing.allocator, .{ .block = inherited_block }, "telar");
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
    const len = try session.read(std.testing.io, &output);
    try std.testing.expectEqual(Exit{ .exited = 0 }, try session.wait());
    try std.testing.expectEqualStrings("xterm-256color|telar|unset", output[0..len]);
}

test "executable lookup uses PATH from the explicit child environment" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var executable = try temp.dir.createFile(io, "telar-path-command", .{ .permissions = File.Permissions.fromMode(0o700) });
    try executable.writeStreamingAll(io, "#!/bin/sh\nprintf 'custom-path'");
    executable.close(io);

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var inherited_map = std.process.Environ.Map.init(std.testing.allocator);
    defer inherited_map.deinit();

    try inherited_map.put("PATH", directory_buffer[0..directory_len]);
    const inherited_block = try inherited_map.createPosixBlock(std.testing.allocator, .{});
    defer inherited_block.deinit(std.testing.allocator);

    var environment = try ChildEnvironment.init(std.testing.allocator, .{ .block = inherited_block }, "telar");
    defer environment.deinit();

    const args = [_][*:0]const u8{"telar-path-command"};
    var command = try Command.fromArgv(&args);
    command.environment = &environment;
    var session = try Session.spawn(&command, .{ .cols = 20, .rows = 5 });
    defer session.deinit();

    var output_buffer: [32]u8 = undefined;
    const output = try readUntil(&session, io, .{ .buffer = &output_buffer, .suffix = "custom-path" });

    try std.testing.expectEqualStrings("custom-path", output);
    try std.testing.expectEqual(Exit{ .exited = 0 }, try session.wait());
}

test "the child starts in the requested working directory" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fmt.bufPrintZ(&cwd_buffer, "{s}", .{directory_buffer[0..directory_len]});
    const args = [_][*:0]const u8{"/bin/pwd"};
    var command = try Command.fromArgv(&args);
    command.cwd = cwd.ptr;
    var session = try Session.spawn(&command, .{ .cols = 20, .rows = 5 });
    defer session.deinit();

    var expected_buffer: [std.fs.max_path_bytes + 2]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{s}\r\n", .{cwd});
    var output_buffer: [std.fs.max_path_bytes + 2]u8 = undefined;
    const output = try readUntil(&session, io, .{ .buffer = &output_buffer, .suffix = expected });

    try std.testing.expectEqualStrings(expected, output);
    try std.testing.expectEqual(Exit{ .exited = 0 }, try session.wait());
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
    const len = try session.read(io, &output);

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

test "foreground inspection identifies the session leader" {
    const io = std.testing.io;
    const args = [_][*:0]const u8{ "/bin/sh", "-c", "printf 'ready\\n'; exec /bin/sleep 60" };
    const command = try Command.fromArgv(&args);
    var session = try Session.spawn(&command, .{ .cols = 20, .rows = 5 });
    defer session.deinit();

    var output_buffer: [16]u8 = undefined;
    _ = try readUntil(&session, io, .{ .buffer = &output_buffer, .suffix = "ready\r\n" });

    try std.testing.expectEqual(session.processId(), session.foregroundProcessGroup().?);
    try std.testing.expect(session.shellForeground().?);

    session.shutdown();
    try std.testing.expectEqual(Exit{ .signaled = .KILL }, try session.wait());
}

test "deinit is idempotent after the child has been reaped" {
    const args = [_][*:0]const u8{ "/bin/sh", "-c", "exit 0" };
    const command = try Command.fromArgv(&args);
    var session = try Session.spawn(&command, .{ .cols = 20, .rows = 5 });

    try std.testing.expectEqual(Exit{ .exited = 0 }, try session.wait());

    session.deinit();
    session.deinit();
    session.shutdown();

    try std.testing.expectError(error.ChildAlreadyReaped, session.wait());
}

test "deinit terminates and reaps a live child" {
    const args = [_][*:0]const u8{ "/bin/sh", "-c", "exec /bin/sleep 60" };
    const command = try Command.fromArgv(&args);
    var session = try Session.spawn(&command, .{ .cols = 20, .rows = 5 });
    const pid = session.processId();

    session.deinit();

    var status: c_int = undefined;
    const result = std.c.waitpid(pid, &status, 0);
    try std.testing.expectEqual(@as(std.c.pid_t, -1), result);
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(result));
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
    while (!session.wait_claimed.load(.acquire)) {
        std.atomic.spinLoopHint();
    }

    try std.testing.expectError(error.ChildWaitAlreadyClaimed, session.wait());

    session.shutdown();
    thread.join();

    try std.testing.expectEqual(@as(?anyerror, null), capture.failure);
    try std.testing.expectEqual(Exit{ .signaled = .KILL }, capture.result.?);
}
