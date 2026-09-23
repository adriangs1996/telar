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
pub fn reset(self: *OutputFrame) void {
    self.* = .{};
    self.writer = .fixed(&self.bytes);
}

/// Consumes available streaming tokens, retaining neither the input nor heap allocations.
/// Example: `scanner.feedInput(chunk); try frame.consume(&scanner);`
pub fn consume(self: *OutputFrame, scanner: *std.json.Scanner) !void {
    while (true) {
        const next = scanner.next() catch |err| switch (err) {
            error.BufferUnderrun => return,
            else => return error.InvalidProviderFrame,
        };
        self.token(next) catch |err| switch (err) {
            error.WriteFailed => return error.ProviderFrameTooLarge,
            else => return err,
        };
        if (next == .end_of_document) {
            return;
        }
    }
}

fn token(self: *OutputFrame, value: std.json.Token) !void {
    switch (value) {
        .object_begin, .array_begin => {
            try self.beginValue();
            if (self.depth == self.containers.len) {
                return error.ProviderFrameTooDeep;
            }

            const object = value == .object_begin;
            try self.writer.writeByte(if (object) '{' else '[');
            self.containers[self.depth] = if (object) .object_first else .array_first;
            self.depth += 1;
            self.is_output = false;
        },
        .object_end, .array_end => {
            self.depth -= 1;
            try self.writer.writeByte(if (value == .object_end) '}' else ']');
        },
        .true, .false, .null => {
            try self.beginValue();
            try self.writer.writeAll(switch (value) {
                .true => "true",
                .false => "false",
                else => "null",
            });
        },
        .partial_number, .number => |part| {
            if (!self.in_number) {
                try self.beginValue();
            }

            try self.writer.writeAll(part);
            self.in_number = value != .number;
        },
        .partial_string, .string => |part| {
            try self.stringPart(part);
            if (value == .string) {
                try self.endString();
            }
        },
        .partial_string_escaped_1 => |part| try self.stringPart(&part),
        .partial_string_escaped_2 => |part| try self.stringPart(&part),
        .partial_string_escaped_3 => |part| try self.stringPart(&part),
        .partial_string_escaped_4 => |part| try self.stringPart(&part),
        .end_of_document => self.complete = true,
        .allocated_string, .allocated_number => unreachable,
    }
}

fn beginValue(self: *OutputFrame) !void {
    if (self.depth == 0) {
        return;
    }

    const container = &self.containers[self.depth - 1];
    switch (container.*) {
        .object_value => container.* = .object_key,
        .array_first => container.* = .array_value,
        .array_value => try self.writer.writeByte(','),
        else => unreachable,
    }
}

fn stringPart(self: *OutputFrame, part: []const u8) !void {
    if (!self.in_string) {
        self.is_key = self.depth != 0 and switch (self.containers[self.depth - 1]) {
            .object_first, .object_key => true,
            else => false,
        };
        if (self.is_key) {
            if (self.containers[self.depth - 1] == .object_key) {
                try self.writer.writeByte(',');
            }

            self.key_len = 0;
            self.is_output = false;
        } else {
            try self.beginValue();
        }

        try self.writer.writeByte('"');
        self.string_start = self.writer.end;
        self.retained = 0;
        self.string_truncated = false;
        self.in_string = true;
    }

    if (self.is_key and self.key_len <= self.key.len) {
        const count = @min(part.len, self.key.len - self.key_len);
        @memcpy(self.key[self.key_len..][0..count], part[0..count]);
        self.key_len = if (count == part.len) self.key_len + count else self.key.len + 1;
    }

    const count = if (self.is_output) @min(part.len, max_output_bytes - self.retained) else part.len;
    try std.json.Stringify.encodeJsonStringChars(part[0..count], .{}, &self.writer);
    if (self.is_output) {
        self.retained += count;
        self.string_truncated = self.string_truncated or count != part.len;
    }
}

fn endString(self: *OutputFrame) !void {
    if (self.string_truncated) {
        // A scanner input boundary or the byte quota can bisect a UTF-8 codepoint.
        const bytes = self.writer.buffered();
        var end = bytes.len;
        while (end > self.string_start and bytes[end - 1] & 0xc0 == 0x80) {
            end -= 1;
        }

        if (end > self.string_start and bytes[end - 1] >= 0xc0) {
            const width = std.unicode.utf8ByteSequenceLength(bytes[end - 1]) catch unreachable;
            if (bytes.len - (end - 1) < width) {
                self.writer.end = end - 1;
            }
        }

        try std.json.Stringify.encodeJsonStringChars(marker, .{}, &self.writer);
        self.truncated = true;
    }

    try self.writer.writeByte('"');
    if (self.is_key) {
        self.is_output = self.key_len <= self.key.len and output_fields.has(self.key[0..self.key_len]);
        try self.writer.writeByte(':');
        self.containers[self.depth - 1] = .object_value;
    } else {
        self.is_output = false;
    }

    self.in_string = false;
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
