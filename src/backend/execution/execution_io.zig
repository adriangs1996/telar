const std = @import("std");
const ExecutionPipes = @import("ExecutionPipes.zig");
const ExecutionCompletion = @import("ExecutionCompletion.zig");
const chunk_bytes = 4096;
const poll_ms = 10;

/// Owns the child and all pipe I/O off the runtime loop. Example: `select.concurrent(.execution_finished, execution_io.start, .{ io, pipes });`.
pub fn start(io: std.Io, pipes: *ExecutionPipes) ExecutionCompletion {
    return .{ .id = pipes.id, .result = collect(io, pipes) };
}

fn collect(io: std.Io, pipes: *ExecutionPipes) !i32 {
    var environment = try std.process.Environ.createMap(pipes.environ, std.heap.page_allocator);
    defer environment.deinit();
    // Runtime-local identity is explicit; inherited pane/workspace identities
    // and authentication forwarding do not belong to an administration command.
    for ([_][]const u8{ "TELAR_PANE_ID", "TELAR_WORKSPACE_ID", "TELAR_TAB_ID", "SSH_AUTH_SOCK" }) |key| {
        _ = environment.swapRemove(key);
    }

    var child = try std.process.spawn(io, .{
        .argv = pipes.arguments,
        .cwd = .{ .path = pipes.cwd },
        .environ_map = &environment,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    const pid = child.id.?;
    var reaped = false;
    defer {
        if (!reaped) {
            _ = std.c.kill(-pid, .KILL);
            child.kill(io);
        }
    }

    try nonblocking(child.stdin.?.handle);
    try nonblocking(child.stdout.?.handle);
    try nonblocking(child.stderr.?.handle);
    pipes.started.store(true, .release);
    var ended = [2]bool{ false, false };
    var status: c_int = 0;
    while (true) {
        try io.checkCancel();
        if (pipes.cancel.load(.acquire)) {
            _ = std.c.kill(-pid, .KILL);
        }

        var pending = [_]std.c.pollfd{
            .{ .fd = if (ended[0]) -1 else child.stdout.?.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = if (ended[1]) -1 else child.stderr.?.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.c.poll(&pending, pending.len, poll_ms);
        for (&ended, 0..) |*closed, index| {
            if (closed.*) {
                continue;
            }

            var bytes: [chunk_bytes]u8 = undefined;
            const count = std.c.read(pending[index].fd, &bytes, bytes.len);
            if (count == 0) {
                closed.* = true;
            } else if (count > 0) {
                lock(io, pipes) catch return error.Canceled;
                if (index == 0) {
                    append(&pipes.stdout, &pipes.stdout_total, bytes[0..@intCast(count)]);
                } else {
                    append(&pipes.stderr, &pipes.stderr_total, bytes[0..@intCast(count)]);
                }

                pipes.guard.unlock();
            } else if (std.posix.errno(count) != .AGAIN and std.posix.errno(count) != .INTR) {
                return error.ExecutionReadFailed;
            }
        }

        if (child.stdin) |input| {
            var bytes: [chunk_bytes]u8 = undefined;
            try lock(io, pipes);
            const count: usize = @intCast(@min(bytes.len, pipes.input_written - pipes.input_read));
            for (bytes[0..count], 0..) |*byte, index| {
                byte.* = pipes.input[(pipes.input_read + index) % pipes.input.len];
            }

            pipes.guard.unlock();
            if (count > 0) {
                const written = std.c.write(input.handle, &bytes, count);
                if (written > 0) {
                    try lock(io, pipes);
                    pipes.input_read += @intCast(written);
                    pipes.guard.unlock();
                } else if (written < 0 and std.posix.errno(written) == .PIPE) {
                    pipes.eof.store(true, .release);
                    input.close(io);
                    child.stdin = null;
                }
            } else if (pipes.eof.load(.acquire)) {
                input.close(io);
                child.stdin = null;
            }
        }

        // Keep the PID owned until both streams close. A descendant retaining
        // a pipe remains part of this execution and can still be cancelled.
        if (ended[0] and ended[1]) {
            const result = std.c.waitpid(pid, &status, std.c.W.NOHANG);
            if (result == pid) {
                reaped = true;
                break;
            }

            if (result < 0 and std.posix.errno(result) != .INTR) {
                return error.ExecutionWaitFailed;
            }
        }
    }

    if (child.stdin) |file| {
        file.close(io);
    }

    child.stdout.?.close(io);
    child.stderr.?.close(io);
    pipes.eof.store(true, .release);
    return if (std.c.W.IFEXITED(@bitCast(status))) @intCast(std.c.W.EXITSTATUS(@bitCast(status))) else @as(i32, 128) + @as(i32, @intCast(@intFromEnum(std.c.W.TERMSIG(@bitCast(status)))));
}

fn nonblocking(fd: std.c.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (flags < 0) {
        return error.ExecutionPipeFailed;
    }

    var options: std.c.O = @bitCast(@as(u32, @intCast(flags)));
    options.NONBLOCK = true;
    if (std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(options))) != 0) {
        return error.ExecutionPipeFailed;
    }
}

fn lock(io: std.Io, pipes: *ExecutionPipes) !void {
    while (!pipes.guard.tryLock()) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn append(buffer: []u8, total: *u64, bytes: []const u8) void {
    for (bytes) |byte| {
        buffer[total.* % buffer.len] = byte;
        total.* += 1;
    }
}
