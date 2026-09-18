const std = @import("std");
const protocol = @import("protocol.zig");
const OutputFrame = @import("OutputFrame.zig");
const Stream = @This();

file: std.Io.File,
buffer: [8192]u8 = undefined,
offset: usize = 0,
buffer_len: usize = 0,
line: [protocol.max_line_bytes]u8 = undefined,
external_line: ?[]u8 = null,
output_frame: ?*OutputFrame = null,
truncated: bool = false,

/// Retains partial records across arbitrary pipe read boundaries.
/// Example: `const line = try stream.next(io);`
pub fn next(stream: *Stream, io: std.Io) anyerror![]const u8 {
    stream.truncated = false;
    const line = stream.external_line orelse &stream.line;
    var line_len: usize = 0;
    while (true) {
        if (stream.offset == stream.buffer_len) {
            try stream.refill(io);
        }

        const available = stream.buffer[stream.offset..stream.buffer_len];
        const newline = std.mem.indexOfScalar(u8, available, '\n');
        const count = newline orelse available.len;
        if (count > line.len - line_len) {
            if (stream.output_frame != null) {
                return stream.readOutput(io, line[0..line_len]);
            }

            return error.ProviderFrameTooLarge;
        }

        @memcpy(line[line_len..][0..count], available[0..count]);
        line_len += count;
        stream.offset += count;
        if (newline != null) {
            stream.offset += 1;
            if (line_len != 0 and line[line_len - 1] == '\r') {
                line_len -= 1;
            }

            return line[0..line_len];
        }
    }
}

fn readOutput(stream: *Stream, io: std.Io, prefix: []const u8) ![]const u8 {
    const frame = stream.output_frame.?;
    frame.reset();
    var nesting: [256]u8 = undefined;
    var allocator: std.heap.FixedBufferAllocator = .init(&nesting);
    var scanner = std.json.Scanner.initStreaming(allocator.allocator());
    defer scanner.deinit();
    scanner.feedInput(prefix);
    try frame.consume(&scanner);
    while (true) {
        if (stream.offset == stream.buffer_len) {
            try stream.refill(io);
        }

        const available = stream.buffer[stream.offset..stream.buffer_len];
        const newline = std.mem.indexOfScalar(u8, available, '\n');
        const count = newline orelse available.len;
        scanner.feedInput(available[0..count]);
        stream.offset += count;
        if (newline != null) {
            stream.offset += 1;
            scanner.endInput();
        }

        try frame.consume(&scanner);
        if (newline != null) {
            std.debug.assert(frame.complete);
            stream.truncated = frame.truncated;
            return frame.writer.buffered();
        }
    }
}

fn refill(stream: *Stream, io: std.Io) !void {
    stream.buffer_len = stream.file.readStreaming(io, &.{&stream.buffer}) catch |err| switch (err) {
        error.EndOfStream => return error.ProviderClosed,
        else => return err,
    };
    stream.offset = 0;
    if (stream.buffer_len == 0) {
        return error.ProviderClosed;
    }
}

test "Codex JSONL framing survives every byte boundary including UTF-8 and CRLF" {
    const io = std.testing.io;
    const expected = "{\"method\":\"example\",\"text\":\"Señal\"}";
    const input = expected ++ "\r\n{\"id\":2}\n";
    for (0..expected.len + 3) |split| {
        var descriptors: [2]std.c.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&descriptors));
        const reader: std.Io.File = .{ .handle = descriptors[0], .flags = .{ .nonblocking = false } };
        defer reader.close(io);
        const writer: std.Io.File = .{ .handle = descriptors[1], .flags = .{ .nonblocking = false } };
        defer writer.close(io);
        try writer.writeStreamingAll(io, input[split..]);
        var stream: Stream = .{ .file = reader, .buffer_len = split };
        @memcpy(stream.buffer[0..split], input[0..split]);
        try std.testing.expectEqualStrings(expected, try stream.next(io));
        try std.testing.expectEqualStrings("{\"id\":2}", try stream.next(io));
    }
}

test "large provider outputs drain to newline with bounded memory and preserve following frames" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(io, "output", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "{\"method\":\"codex/event/exec_command_end\",\"params\":{\"stdout\":\"");
    const chunk = "\\u0000\\ufffd\\n\\\"\\\\" ** 512;
    for (0..256) |_| {
        try file.writeStreamingAll(io, chunk);
    }

    try file.writeStreamingAll(io, "\",\"aggregated_output\":\"");
    for (0..256) |_| {
        try file.writeStreamingAll(io, chunk);
    }

    try file.writeStreamingAll(io, "\",\"exit_code\":7},\"idAfterOutput\":\"unchanged\"}\r\n{\"id\":2}\n");
    const reader = try temp.dir.openFile(io, "output", .{});
    defer reader.close(io);
    var frame: OutputFrame = .{};
    var stream: Stream = .{ .file = reader, .output_frame = &frame };
    const line = try stream.next(io);
    try std.testing.expect(stream.truncated);
    try std.testing.expect(line.len < protocol.max_line_bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    const params = protocol.field(parsed.value, "params");
    const output = protocol.string(protocol.field(params, "stdout"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(output));
    try std.testing.expect(std.mem.endsWith(u8, output, OutputFrame.marker));
    try std.testing.expectEqualStrings(output, protocol.string(protocol.field(params, "aggregated_output")));
    try std.testing.expectEqual(@as(i64, 7), protocol.field(params, "exit_code").integer);
    try std.testing.expectEqualStrings("unchanged", protocol.string(protocol.field(parsed.value, "idAfterOutput")));
    try std.testing.expectEqualStrings("{\"id\":2}", try stream.next(io));
    try std.testing.expect(!stream.truncated);
    try std.testing.expectError(error.ProviderClosed, stream.next(io));

    const strict_reader = try temp.dir.openFile(io, "output", .{});
    defer strict_reader.close(io);
    var strict: Stream = .{ .file = strict_reader };
    try std.testing.expectError(error.ProviderFrameTooLarge, strict.next(io));
}

test "large provider output cannot hide malformed discarded content or missing newline" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const prefix = "{\"text\":\"" ++ "a" ** (protocol.max_line_bytes + 1);
    try temp.dir.writeFile(io, .{ .sub_path = "malformed", .data = prefix ++ "\\q\"}\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "incomplete", .data = prefix });
    const malformed = try temp.dir.openFile(io, "malformed", .{});
    defer malformed.close(io);
    const incomplete = try temp.dir.openFile(io, "incomplete", .{});
    defer incomplete.close(io);
    var frame: OutputFrame = .{};
    var stream: Stream = .{ .file = malformed, .output_frame = &frame };
    try std.testing.expectError(error.InvalidProviderFrame, stream.next(io));
    stream = .{ .file = incomplete, .output_frame = &frame };
    try std.testing.expectError(error.ProviderClosed, stream.next(io));
}

test "large provider output drain remains cancellable before the newline" {
    const io = std.testing.io;
    var descriptors: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&descriptors));
    const reader: std.Io.File = .{ .handle = descriptors[0], .flags = .{ .nonblocking = false } };
    defer reader.close(io);
    const writer: std.Io.File = .{ .handle = descriptors[1], .flags = .{ .nonblocking = false } };
    defer writer.close(io);
    var frame: OutputFrame = .{};
    var stream: Stream = .{ .file = reader, .output_frame = &frame };
    var future = try io.concurrent(next, .{ &stream, io });
    defer _ = future.cancel(io) catch {};
    try writer.writeStreamingAll(io, "{\"delta\":\"");
    const chunk = [_]u8{'x'} ** 8192;
    for (0..128) |_| {
        try writer.writeStreamingAll(io, &chunk);
    }

    try std.testing.expectError(error.Canceled, future.cancel(io));
}
