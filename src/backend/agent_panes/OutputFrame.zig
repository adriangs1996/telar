const std = @import("std");
const protocol = @import("protocol.zig");
const OutputFrame = @This();

pub const max_output_bytes = 8 * 1024;
pub const marker = "\n[Output truncated by Telar]";
const Container = enum { object_first, object_key, object_value, array_first, array_value };
const output_fields = std.StaticStringMap(void).initComptime(.{
    .{ "stdout", {} },           .{ "stderr", {} },           .{ "aggregated_output", {} },
    .{ "aggregatedOutput", {} }, .{ "formatted_output", {} }, .{ "output", {} },
    .{ "text", {} },             .{ "delta", {} },            .{ "diff", {} },
    .{ "data", {} },
});

bytes: [protocol.max_line_bytes]u8 = undefined,
writer: std.Io.Writer = undefined,
containers: [64]Container = undefined,
depth: usize = 0,
key: [32]u8 = undefined,
key_len: usize = 0,
is_key: bool = false,
is_output: bool = false,
in_string: bool = false,
in_number: bool = false,
string_start: usize = 0,
retained: usize = 0,
string_truncated: bool = false,
truncated: bool = false,
complete: bool = false,

/// Projects large output strings into a bounded preview without changing control fields.
/// The scanner still validates discarded bytes; this scratch belongs to the observation actor.
/// Example: `frame.reset(); try frame.consume(&scanner);`
pub fn reset(frame: *OutputFrame) void {
    frame.* = .{};
    frame.writer = .fixed(&frame.bytes);
}

/// Consumes available streaming tokens, retaining neither the input nor heap allocations.
/// Example: `scanner.feedInput(chunk); try frame.consume(&scanner);`
pub fn consume(frame: *OutputFrame, scanner: *std.json.Scanner) !void {
    while (true) {
        const next = scanner.next() catch |err| switch (err) {
            error.BufferUnderrun => return,
            else => return error.InvalidProviderFrame,
        };
        frame.token(next) catch |err| switch (err) {
            error.WriteFailed => return error.ProviderFrameTooLarge,
            else => return err,
        };
        if (next == .end_of_document) {
            return;
        }
    }
}

fn token(frame: *OutputFrame, value: std.json.Token) !void {
    switch (value) {
        .object_begin, .array_begin => {
            try frame.beginValue();
            if (frame.depth == frame.containers.len) {
                return error.ProviderFrameTooDeep;
            }

            const object = value == .object_begin;
            try frame.writer.writeByte(if (object) '{' else '[');
            frame.containers[frame.depth] = if (object) .object_first else .array_first;
            frame.depth += 1;
            frame.is_output = false;
        },
        .object_end, .array_end => {
            frame.depth -= 1;
            try frame.writer.writeByte(if (value == .object_end) '}' else ']');
        },
        .true, .false, .null => {
            try frame.beginValue();
            try frame.writer.writeAll(switch (value) {
                .true => "true",
                .false => "false",
                else => "null",
            });
        },
        .partial_number, .number => |part| {
            if (!frame.in_number) {
                try frame.beginValue();
            }

            try frame.writer.writeAll(part);
            frame.in_number = value != .number;
        },
        .partial_string, .string => |part| {
            try frame.stringPart(part);
            if (value == .string) {
                try frame.endString();
            }
        },
        .partial_string_escaped_1 => |part| try frame.stringPart(&part),
        .partial_string_escaped_2 => |part| try frame.stringPart(&part),
        .partial_string_escaped_3 => |part| try frame.stringPart(&part),
        .partial_string_escaped_4 => |part| try frame.stringPart(&part),
        .end_of_document => frame.complete = true,
        .allocated_string, .allocated_number => unreachable,
    }
}

fn beginValue(frame: *OutputFrame) !void {
    if (frame.depth == 0) {
        return;
    }

    const container = &frame.containers[frame.depth - 1];
    switch (container.*) {
        .object_value => container.* = .object_key,
        .array_first => container.* = .array_value,
        .array_value => try frame.writer.writeByte(','),
        else => unreachable,
    }
}

fn stringPart(frame: *OutputFrame, part: []const u8) !void {
    if (!frame.in_string) {
        frame.is_key = frame.depth != 0 and switch (frame.containers[frame.depth - 1]) {
            .object_first, .object_key => true,
            else => false,
        };
        if (frame.is_key) {
            if (frame.containers[frame.depth - 1] == .object_key) {
                try frame.writer.writeByte(',');
            }

            frame.key_len = 0;
            frame.is_output = false;
        } else {
            try frame.beginValue();
        }

        try frame.writer.writeByte('"');
        frame.string_start = frame.writer.end;
        frame.retained = 0;
        frame.string_truncated = false;
        frame.in_string = true;
    }

    if (frame.is_key and frame.key_len <= frame.key.len) {
        const count = @min(part.len, frame.key.len - frame.key_len);
        @memcpy(frame.key[frame.key_len..][0..count], part[0..count]);
        frame.key_len = if (count == part.len) frame.key_len + count else frame.key.len + 1;
    }

    const count = if (frame.is_output) @min(part.len, max_output_bytes - frame.retained) else part.len;
    try std.json.Stringify.encodeJsonStringChars(part[0..count], .{}, &frame.writer);
    if (frame.is_output) {
        frame.retained += count;
        frame.string_truncated = frame.string_truncated or count != part.len;
    }
}

fn endString(frame: *OutputFrame) !void {
    if (frame.string_truncated) {
        // A scanner input boundary or the byte quota can bisect a UTF-8 codepoint.
        const bytes = frame.writer.buffered();
        var end = bytes.len;
        while (end > frame.string_start and bytes[end - 1] & 0xc0 == 0x80) {
            end -= 1;
        }

        if (end > frame.string_start and bytes[end - 1] >= 0xc0) {
            const width = std.unicode.utf8ByteSequenceLength(bytes[end - 1]) catch unreachable;
            if (bytes.len - (end - 1) < width) {
                frame.writer.end = end - 1;
            }
        }

        try std.json.Stringify.encodeJsonStringChars(marker, .{}, &frame.writer);
        frame.truncated = true;
    }

    try frame.writer.writeByte('"');
    if (frame.is_key) {
        frame.is_output = frame.key_len <= frame.key.len and output_fields.has(frame.key[0..frame.key_len]);
        try frame.writer.writeByte(':');
        frame.containers[frame.depth - 1] = .object_value;
    } else {
        frame.is_output = false;
    }

    frame.in_string = false;
}

test "output projection preserves JSON values across every input boundary" {
    const input = "{\"params\":{\"te\\u0078t\":\"Señal 🧵 \\ud83e\\uddf5 \\n\\\"\\\\\",\"items\":[-12.5e+3,true,false,null,{},[]]},\"id\":9}";
    for (0..input.len + 1) |split| {
        var frame: OutputFrame = .{};
        frame.reset();
        var nesting: [256]u8 = undefined;
        var allocator: std.heap.FixedBufferAllocator = .init(&nesting);
        var scanner = std.json.Scanner.initStreaming(allocator.allocator());
        defer scanner.deinit();
        scanner.feedInput(input[0..split]);
        try frame.consume(&scanner);
        scanner.feedInput(input[split..]);
        scanner.endInput();
        try frame.consume(&scanner);
        try std.testing.expect(frame.complete and !frame.truncated);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, frame.writer.buffered(), .{});
        defer parsed.deinit();
        const params = protocol.field(parsed.value, "params");
        try std.testing.expectEqualStrings("Señal 🧵 🧵 \n\"\\", protocol.string(protocol.field(params, "text")));
        try std.testing.expectEqual(@as(i64, 9), protocol.field(parsed.value, "id").integer);
        const items = protocol.field(params, "items").array.items;
        try std.testing.expectEqual(@as(f64, -12500), items[0].float);
        try std.testing.expect(items[1].bool and !items[2].bool and items[3] == .null);
        try std.testing.expect(items[4] == .object and items[5] == .array);
    }
}

test "output projection validates discarded escapes and keeps UTF8 preview boundaries" {
    const prefix = "{\"aggregatedOutput\":\"";
    const padding = [_]u8{'a'} ** (max_output_bytes - 1);
    const suffixes = [_][]const u8{ "ñ", "🧵", "\\ud83e\\uddf5" };
    for (suffixes) |suffix| {
        for (0..suffix.len + 1) |split| {
            var frame: OutputFrame = .{};
            frame.reset();
            var scanner = std.json.Scanner.initStreaming(std.testing.allocator);
            defer scanner.deinit();
            for ([_][]const u8{ prefix, &padding, suffix[0..split], suffix[split..], "\",\"exitCode\":7}" }) |chunk| {
                scanner.feedInput(chunk);
                try frame.consume(&scanner);
            }

            scanner.endInput();
            try frame.consume(&scanner);
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, frame.writer.buffered(), .{});
            defer parsed.deinit();
            const output = protocol.string(protocol.field(parsed.value, "aggregatedOutput"));
            try std.testing.expect(frame.truncated);
            try std.testing.expectEqualStrings(&padding ++ marker, output);
            try std.testing.expectEqual(@as(i64, 7), protocol.field(parsed.value, "exitCode").integer);
        }
    }

    var frame: OutputFrame = .{};
    frame.reset();
    var scanner = std.json.Scanner.initStreaming(std.testing.allocator);
    defer scanner.deinit();
    scanner.feedInput(prefix ++ padding ++ "abcd");
    try frame.consume(&scanner);
    scanner.feedInput("\\q\"}");
    scanner.endInput();
    try std.testing.expectError(error.InvalidProviderFrame, frame.consume(&scanner));
}

test "output projection bounds metadata and nesting instead of truncating authority" {
    var frame: OutputFrame = .{};
    frame.reset();
    var scanner = std.json.Scanner.initStreaming(std.testing.allocator);
    defer scanner.deinit();
    scanner.feedInput("{\"command\":\"");
    try frame.consume(&scanner);
    const chunk = [_]u8{'x'} ** 8192;
    for (0..31) |_| {
        scanner.feedInput(&chunk);
        try frame.consume(&scanner);
    }

    scanner.feedInput(&chunk);
    try std.testing.expectError(error.ProviderFrameTooLarge, frame.consume(&scanner));
    try std.testing.expect(!frame.truncated);
    frame.reset();
    var deep = std.json.Scanner.initCompleteInput(std.testing.allocator, "[" ** 65);
    defer deep.deinit();
    try std.testing.expectError(error.ProviderFrameTooDeep, frame.consume(&deep));
}
