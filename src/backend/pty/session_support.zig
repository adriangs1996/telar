//! Live child-process and PTY ownership for one runtime pane.

const std = @import("std");
const command_mod = @import("command_support.zig");
const environment_mod = @import("environment.zig");
const exit_mod = @import("exit.zig");
const native = @import("native.zig");
const spawn_mod = @import("spawn.zig");

pub const Command = command_mod.Command;
const ChildEnvironment = environment_mod.ChildEnvironment;
pub const File = std.Io.File;

pub const Exit = exit_mod.Exit;

pub const Size = @import("Size.zig");

pub const Session = @import("Session.zig");

pub fn windowSize(requested: Size) std.posix.winsize {
    const size = requested.valid();
    return .{
        .row = size.rows,
        .col = size.cols,
        .xpixel = std.math.mul(u16, size.cols, size.cell_width_px) catch std.math.maxInt(u16),
        .ypixel = std.math.mul(u16, size.rows, size.cell_height_px) catch std.math.maxInt(u16),
    };
}

const ReadExpectation = @import("ReadExpectation.zig");

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
    try inherited_map.put("TERM_PROGRAM_VERSION", "outer-version");
    const inherited_block = try inherited_map.createPosixBlock(std.testing.allocator, .{});
    defer inherited_block.deinit(std.testing.allocator);

    var environment = try ChildEnvironment.init(std.testing.allocator, .{ .block = inherited_block }, "telar");
    defer environment.deinit();

    const args = [_][*:0]const u8{
        "sh",
        "-c",
        "printf '%s|%s|%s|%s|%s|%s' \"$TERM\" \"$COLORTERM\" \"$TERM_PROGRAM\" \"$TELAR_TERM_PROGRAM\" \"${TERM_PROGRAM_VERSION-unset}\" \"${GHOSTTY_RESOURCES_DIR-unset}\"",
    };
    var command = try Command.fromArgv(&args);
    command.environment = &environment;
    var session = try Session.spawn(&command, .{ .cols = 40, .rows = 5 });
    defer session.deinit();

    var output: [128]u8 = undefined;
    const len = try session.read(std.testing.io, &output);
    try std.testing.expectEqual(Exit{ .exited = 0 }, try session.wait());
    try std.testing.expectEqualStrings("xterm-256color|truecolor|ghostty|telar|unset|unset", output[0..len]);
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

test "foreground inspection follows a foreground job rather than its shell" {
    const io = std.testing.io;
    const args = [_][*:0]const u8{ "/bin/sh", "-c", "set -m; /bin/sh -c 'printf \"ready\\n\"; exec /bin/sleep 60'; :" };
    const command = try Command.fromArgv(&args);
    var session = try Session.spawn(&command, .{ .cols = 20, .rows = 5 });
    defer session.deinit();

    var output_buffer: [256]u8 = undefined;
    _ = try readUntil(&session, io, .{ .buffer = &output_buffer, .suffix = "ready\r\n" });
    const foreground = session.foregroundProcessGroup().?;
    try std.testing.expect(foreground != session.processId());
    try std.testing.expect(!session.shellForeground().?);

    session.shutdown();
    _ = try session.wait();
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
