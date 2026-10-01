const std = @import("std");
const bytecodec = @import("bytecodec");
const id = @import("../id.zig");
const tags = @import("tags.zig");
const ExecutionRequest = @import("ExecutionRequest.zig");
const ExecutionReply = @import("ExecutionReply.zig");

/// Encodes a bounded execution operation. Example: `try encodeExecutionRequest(buffer, request);`.
pub fn encodeExecutionRequest(buffer: []u8, request: ExecutionRequest) ![]const u8 {
    try validate(request);
    var encoder = bytecodec.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.execution_request));
    try encoder.writeInt(u64, id.raw(request.request_id));
    try encoder.writeByte(@intFromEnum(request.action));
    inline for (.{ "execution_id", "workspace_id", "stdout_offset", "stderr_offset", "input_offset" }) |field| {
        try encoder.writeInt(u64, @field(request, field));
    }

    try encoder.writeByte(@intFromBool(request.stdin_open));
    try encoder.writeSized16(request.cwd);
    try encoder.writeByte(request.argument_count);
    for (request.arguments[0..request.argument_count]) |argument| {
        try encoder.writeSized16(argument);
    }

    try encoder.writeSized16(request.bytes);
    return encoder.finish();
}

/// Decodes one operation; the frame owns its slices. Example: `try decodeExecutionRequest(&decoder);`.
pub fn decodeExecutionRequest(decoder: *bytecodec.Decoder) !ExecutionRequest {
    var request: ExecutionRequest = .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .action = std.enums.fromInt(ExecutionRequest.Action, try decoder.readByte()) orelse return error.InvalidExecutionAction,
        .execution_id = try decoder.readInt(u64),
    };
    inline for (.{ "workspace_id", "stdout_offset", "stderr_offset", "input_offset" }) |field| {
        @field(request, field) = try decoder.readInt(u64);
    }

    request.stdin_open = try decoder.readBool();
    request.cwd = try decoder.readSized16();
    request.argument_count = try decoder.readByte();
    if (request.argument_count > ExecutionRequest.max_arguments) {
        return error.InvalidExecutionArguments;
    }

    for (request.arguments[0..request.argument_count]) |*argument| {
        argument.* = try decoder.readSized16();
    }

    request.bytes = try decoder.readSized16();
    try validate(request);
    return request;
}

fn validate(request: ExecutionRequest) !void {
    if ((request.execution_id == 0 and request.action != .list) or request.request_id == .none or request.argument_count > ExecutionRequest.max_arguments or request.bytes.len > ExecutionRequest.max_chunk) {
        return error.InvalidExecutionRequest;
    }

    if (request.cwd.len > 4096 or std.mem.indexOfScalar(u8, request.cwd, 0) != null or (request.cwd.len != 0 and !std.fs.path.isAbsolutePosix(request.cwd))) {
        return error.InvalidExecutionCwd;
    }

    if (request.action == .start and (request.argument_count == 0 or request.arguments[0].len == 0)) {
        return error.InvalidExecutionArguments;
    }

    var total: usize = 0;
    for (request.arguments[0..request.argument_count]) |argument| {
        total += argument.len;
        if (std.mem.indexOfScalar(u8, argument, 0) != null or total > ExecutionRequest.max_launch_bytes) {
            return error.InvalidExecutionArguments;
        }
    }
}

/// Encodes independent binary streams and their absolute cursors. Example: `try encodeExecutionReply(buffer, reply);`.
pub fn encodeExecutionReply(buffer: []u8, reply: ExecutionReply) ![]const u8 {
    var encoder = bytecodec.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.execution_reply));
    try encoder.writeInt(u64, id.raw(reply.request_id));
    inline for (.{ "execution_id", "workspace_id", "stdout_offset", "stderr_offset", "stdout_total", "stderr_total", "input_offset", "input_available" }) |field| {
        try encoder.writeInt(u64, @field(reply, field));
    }

    try encoder.writeByte(@intFromEnum(reply.state));
    try encoder.writeInt(i32, reply.exit_code);
    try encoder.writeByte(@intFromBool(reply.stdin_open));
    if (reply.failure_len > reply.failure.len) {
        return error.InvalidExecutionReply;
    }

    try encoder.writeSized16(reply.failure[0..reply.failure_len]);
    if (reply.stdout_len > reply.stdout.len or reply.stderr_len > reply.stderr.len) {
        return error.InvalidExecutionReply;
    }

    try encoder.writeSized16(reply.stdout[0..reply.stdout_len]);
    try encoder.writeSized16(reply.stderr[0..reply.stderr_len]);
    return encoder.finish();
}

/// Decodes a bounded stream snapshot. Example: `try decodeExecutionReply(&decoder);`.
pub fn decodeExecutionReply(decoder: *bytecodec.Decoder) !ExecutionReply {
    var reply: ExecutionReply = .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .execution_id = try decoder.readInt(u64),
    };
    inline for (.{ "workspace_id", "stdout_offset", "stderr_offset", "stdout_total", "stderr_total", "input_offset", "input_available" }) |field| {
        @field(reply, field) = try decoder.readInt(u64);
    }

    reply.state = std.enums.fromInt(ExecutionReply.State, try decoder.readByte()) orelse return error.InvalidExecutionState;
    reply.exit_code = try decoder.readInt(i32);
    reply.stdin_open = try decoder.readBool();
    const failure = try decoder.readSized16();
    if (failure.len > reply.failure.len) {
        return error.InvalidExecutionReply;
    }

    @memcpy(reply.failure[0..failure.len], failure);
    reply.failure_len = @intCast(failure.len);
    inline for (.{ "stdout", "stderr" }) |field| {
        const bytes = try decoder.readSized16();
        if (bytes.len > ExecutionRequest.max_chunk) {
            return error.InvalidExecutionReply;
        }

        @memcpy(@field(reply, field)[0..bytes.len], bytes);
        @field(reply, field ++ "_len") = @intCast(bytes.len);
    }

    return reply;
}
