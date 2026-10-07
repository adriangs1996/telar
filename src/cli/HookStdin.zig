//! The JSON one hook event wrote to `telar hook` on standard input. A
//! payload past `max_input_bytes` is not lost: the top-level members that
//! arrived whole before the limit are kept as a smaller JSON object, so the
//! event still reports its state, and the limit is reported.
const std = @import("std");
const core = @import("telar-core");
const HookStdin = @This();

/// Bytes of hook input read before the rest is discarded. A `Write` of a
/// large file arrives whole in `tool_input` and again in `tool_response`,
/// so this leaves room for files of several megabytes.
pub const max_input_bytes = 16 * 1024 * 1024;

/// Bytes of the reader's own buffer between the pipe and `text`.
const read_buffer_bytes = 4096;

/// JSON text owned by the allocator passed to `read`: the whole input, or
/// the members kept from its prefix.
text: []u8,
/// Set when the input passed `max_input_bytes`.
limit: ?core.LimitReach = null,

/// Reads one hook event, discarding what passes `max_input_bytes` so the
/// agent writing the pipe never blocks on it.
///
/// ```zig
/// var stdin = try HookStdin.read(init);
/// defer stdin.deinit(init.gpa);
/// ```
pub fn read(init: std.process.Init) !HookStdin {
    var read_buffer: [read_buffer_bytes]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &read_buffer);
    return readFrom(init.gpa, &stdin_reader.interface, max_input_bytes);
}

pub fn deinit(self: *HookStdin, gpa: std.mem.Allocator) void {
    gpa.free(self.text);
}

fn readFrom(gpa: std.mem.Allocator, reader: *std.Io.Reader, limit: usize) !HookStdin {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);

    // One byte past the limit tells a payload of exactly `limit` bytes
    // from a longer one.
    reader.appendRemaining(gpa, &input, .limited(limit + 1)) catch |err| switch (err) {
        error.StreamTooLong => {
            const discarded = reader.discardRemaining() catch 0;
            return .{
                .text = try keepWholeMembers(gpa, input.items[0..limit]),
                .limit = .{
                    .limit = core.Limit.declare("hooks.max_input_bytes", "bytes", limit),
                    .requested = input.items.len + discarded,
                },
            };
        },
        else => |other| return other,
    };

    return .{
        .text = try input.toOwnedSlice(gpa),
    };
}

/// Copies the top-level members of an object cut short into a complete
/// object. A member whose value did not end before the cut, and the one
/// value the cut may have ended early (a number), are left out.
fn keepWholeMembers(gpa: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();

    try output.writer.writeByte('{');
    var scanner = std.json.Scanner.initCompleteInput(gpa, prefix);
    defer scanner.deinit();

    const opened = scanner.next() catch null;
    if (opened != null and opened.? == .object_begin) {
        try copyMembers(gpa, &scanner, prefix, &output.writer);
    }

    try output.writer.writeByte('}');
    return output.toOwnedSlice();
}

fn copyMembers(gpa: std.mem.Allocator, scanner: *std.json.Scanner, prefix: []const u8, writer: *std.Io.Writer) !void {
    var members: usize = 0;
    while (true) {
        const token = scanner.nextAlloc(gpa, .alloc_always) catch return;
        const key = switch (token) {
            .allocated_string => |key| key,
            else => return,
        };
        defer gpa.free(key);

        const start = scanner.cursor;
        scanner.skipValue() catch return;
        const end = scanner.cursor;

        // What follows the value proves the cut did not shorten it.
        _ = scanner.peekNextTokenType() catch return;
        const value = std.mem.trimStart(u8, prefix[start..end], " \t\r\n:");
        if (members != 0) {
            try writer.writeByte(',');
        }

        try std.json.Stringify.value(key, .{}, writer);
        try writer.writeByte(':');
        try writer.writeAll(value);
        members += 1;
    }
}
