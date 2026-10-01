const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const ExecOptions = @import("arguments/ExecOptions.zig");
const poll_ms = 10;
const failure_status = 125;
const timeout_status = 124;

/// Runs an execution command over the ordinary control connection. Example: `return execution.run(init, options);`.
pub fn run(init: std.process.Init, options: ExecOptions) u8 {
    var session = Session.open(init, options.socket) catch |err| {
        std.debug.print("telar exec: {s}\n", .{@errorName(err)});
        return failure_status;
    };
    defer session.close();
    return start(init, &session, options) catch |err| {
        std.debug.print("telar exec: {s}\n", .{session.failure_reason orelse @errorName(err)});
        return failure_status;
    };
}

fn start(init: std.process.Init, session: *Session, options: ExecOptions) !u8 {
    if (options.action == .list) {
        try list(init, session);
        return 0;
    }

    var operation: core.ExecutionRequest = .{
        .action = switch (options.action) {
            .start => .start,
            .status, .output => .status,
            .cancel => .cancel,
            .forget => .forget,
            .list => unreachable,
        },
        .execution_id = options.id,
        .workspace_id = options.workspace,
        .cwd = options.cwd,
        .stdin_open = options.stdin and !options.detach,
        .stdout_offset = options.stdout_offset,
        .stderr_offset = options.stderr_offset,
    };
    if (operation.execution_id == 0) {
        while (operation.execution_id == 0) {
            init.io.random(std.mem.asBytes(&operation.execution_id));
        }
    }

    operation.argument_count = @intCast(options.arguments.len);
    for (options.arguments, 0..) |argument, index| {
        operation.arguments[index] = std.mem.span(argument);
    }

    errdefer if (options.action == .start) {
        std.debug.print("telar exec: query execution {d} before retrying an uncertain launch\n", .{operation.execution_id});
    };

    var reply = try exchange(session, operation);
    if (options.action == .status or options.action == .cancel or options.action == .forget or options.detach) {
        try printStatus(init, reply);
        return 0;
    }

    if (options.action == .output) {
        return output(init, session, operation, reply);
    }

    const started = session.nowMs();
    var stdin_open = operation.stdin_open;
    operation.action = .status;
    operation.argument_count = 0;
    operation.cwd = "";
    while (true) {
        try writeStreams(init, &operation, reply);
        if ((reply.state == .exited or reply.state == .failed) and operation.stdout_offset == reply.stdout_total and operation.stderr_offset == reply.stderr_total) {
            if (reply.state == .failed) {
                std.debug.print("telar exec: {s}\n", .{reply.failure[0..reply.failure_len]});
            }

            return @intCast(@min(255, @max(0, reply.exit_code)));
        }

        if (options.timeout_seconds != 0 and session.nowMs() - started >= @as(i64, options.timeout_seconds) * std.time.ms_per_s) {
            std.debug.print("telar exec: wait timed out; execution {d} continues\n", .{operation.execution_id});
            return timeout_status;
        }

        if (stdin_open and reply.stdin_open and reply.input_available >= core.ExecutionRequest.max_chunk) {
            var pending = [_]std.c.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
            if (std.c.poll(&pending, 1, 0) > 0) {
                var bytes: [core.ExecutionRequest.max_chunk]u8 = undefined;
                const count = std.c.read(0, &bytes, bytes.len);
                if (count < 0) {
                    return error.ExecutionStdinFailed;
                }

                var input = operation;
                input.action = if (count == 0) .eof else .input;
                input.bytes = bytes[0..@intCast(count)];
                input.input_offset = reply.input_offset;
                reply = try exchange(session, input);
                stdin_open = count != 0;
                continue;
            }
        }

        if (reply.stdout_len == 0 and reply.stderr_len == 0) {
            try init.io.sleep(.fromMilliseconds(poll_ms), .awake);
        }

        reply = try exchange(session, operation);
    }
}

/// Retries bounded pipe contention; never retries a transport failure. Example: `const reply = try execution.exchange(&session, request);`.
pub fn exchange(session: *Session, operation: core.ExecutionRequest) !core.ExecutionReply {
    while (true) {
        const response = session.exchange(core.encodeExecutionRequest, operation) catch |err| {
            if (session.failure_reason) |reason| {
                if (std.mem.eql(u8, reason, "ExecutionBusy")) {
                    session.sleepMs(poll_ms);
                    continue;
                }
            }

            return err;
        };
        switch (response) {
            .execution_reply => |reply| return reply,
            .request_failed => |failure| {
                if (std.mem.eql(u8, failure.message, "ExecutionBusy")) {
                    session.sleepMs(poll_ms);
                    continue;
                }

                session.failure_reason = failure.message;
                return error.ExecutionRefused;
            },
            else => return error.UnexpectedRuntimeResponse,
        }
    }
}

fn writeStreams(init: std.process.Init, operation: *core.ExecutionRequest, reply: core.ExecutionReply) !void {
    if (reply.stdout_offset != operation.stdout_offset or reply.stderr_offset != operation.stderr_offset) {
        std.debug.print("telar exec: retained output lost; resume with --stdout-offset {d} --stderr-offset {d}\n", .{ reply.stdout_offset, reply.stderr_offset });
        return error.ExecutionOutputLost;
    }

    try std.Io.File.stdout().writeStreamingAll(init.io, reply.stdout[0..reply.stdout_len]);
    try std.Io.File.stderr().writeStreamingAll(init.io, reply.stderr[0..reply.stderr_len]);
    operation.stdout_offset += reply.stdout_len;
    operation.stderr_offset += reply.stderr_len;
}

fn output(init: std.process.Init, session: *Session, request: core.ExecutionRequest, first: core.ExecutionReply) !u8 {
    var operation = request;
    var reply = first;
    const stdout_end = first.stdout_total;
    const stderr_end = first.stderr_total;
    while (true) {
        try writeStreams(init, &operation, reply);
        if (operation.stdout_offset >= stdout_end and operation.stderr_offset >= stderr_end) {
            return 0;
        }

        reply = try exchange(session, operation);
    }
}

fn printStatus(init: std.process.Init, reply: core.ExecutionReply) !void {
    var buffer: [2048]u8 = undefined;
    var output_writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try std.json.Stringify.value(.{
        .execution_id = reply.execution_id,
        .workspace_id = reply.workspace_id,
        .state = @tagName(reply.state),
        .exit_code = if (reply.state == .exited or reply.state == .failed) @as(?i32, reply.exit_code) else null,
        .stdout_offset = reply.stdout_offset,
        .stderr_offset = reply.stderr_offset,
        .stdout_bytes = reply.stdout_total,
        .stderr_bytes = reply.stderr_total,
        .stdin_bytes = reply.input_offset,
        .stdin_open = reply.stdin_open,
        .failure = reply.failure[0..reply.failure_len],
    }, .{}, &output_writer.interface);
    try output_writer.interface.writeByte('\n');
    try output_writer.interface.flush();
}

fn list(init: std.process.Init, session: *Session) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    var operation: core.ExecutionRequest = .{ .action = .list, .execution_id = 0 };
    try writer.interface.writeByte('[');
    while (true) {
        const reply = try exchange(session, operation);
        if (reply.execution_id == 0) {
            break;
        }

        if (operation.execution_id != 0) {
            try writer.interface.writeByte(',');
        }

        try std.json.Stringify.value(.{
            .execution_id = reply.execution_id,
            .workspace_id = reply.workspace_id,
            .state = @tagName(reply.state),
            .exit_code = if (reply.state == .exited or reply.state == .failed) @as(?i32, reply.exit_code) else null,
        }, .{}, &writer.interface);
        operation.execution_id = reply.execution_id;
    }

    try writer.interface.writeAll("]\n");
    try writer.interface.flush();
}
