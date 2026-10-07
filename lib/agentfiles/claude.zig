//! The session name Claude Code writes to its transcript. `/rename` fires no
//! hook: the name only lands as a `custom-title` line in the JSONL file the
//! hooks point at. `probe` reads what was appended since the last offset;
//! `scan` is the pure pass over those bytes.

const std = @import("std");
const utf8 = @import("utf8.zig");
const TitleProbe = @import("TitleProbe.zig");

/// Bytes one probe reads; a longer backlog continues on the next probe.
pub const max_scan_bytes = 64 * 1024;
/// A title line longer than this is skipped rather than parsed.
pub const max_line_bytes = 4096;
const title_prefix = "{\"type\":\"custom-title\"";

/// Finds the last `custom-title` line for `session` among the complete lines
/// in `bytes`. Other lines are skipped by prefix without parsing, so a
/// transcript full of large messages costs one scan for newlines.
///
/// ```zig
/// const result = scan(bytes, "0192...", &title_buffer);
/// ```
pub fn scan(bytes: []const u8, session: []const u8, buffer: []u8) Scan {
    var result: Scan = .{ .consumed = 0, .title = null };
    var rest = bytes;

    while (std.mem.indexOfScalar(u8, rest, '\n')) |newline| {
        const line = rest[0..newline];
        result.consumed += newline + 1;
        rest = rest[newline + 1 ..];
        if (!std.mem.startsWith(u8, line, title_prefix) or line.len > max_line_bytes) {
            continue;
        }

        var parse_buffer: [4 * max_line_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&parse_buffer);
        const parsed = std.json.parseFromSliceLeaky(TitleLine, fixed.allocator(), line, .{ .ignore_unknown_fields = true }) catch continue;
        if (!std.mem.eql(u8, parsed.sessionId, session)) {
            continue;
        }

        result.title = utf8.truncate(buffer, parsed.customTitle);
    }

    return result;
}

/// Probes the transcript at `path` for `session`. The first probe of a watch
/// (`offset` null) only records where the file ends; later probes read at
/// most `max_scan_bytes` past the offset and leave the rest for the next
/// one. Claude Code creates the transcript lazily, so a file that does not
/// exist yet is seeded at zero and read whole once it appears. A file shorter
/// than the offset was rewritten and is read again. The title borrows
/// `title_buffer`, cut at a UTF-8 boundary to its length.
///
/// ```zig
/// const result = claude.probe(io, path, session, watch.offset, &title_buffer);
/// ```
pub fn probe(io: std.Io, path: []const u8, session: []const u8, offset: ?u64, title_buffer: []u8) TitleProbe {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
        return .{ .offset = if (offset == null) 0 else null };
    };
    defer file.close(io);
    const length = file.length(io) catch return .{};
    const start = offset orelse return .{ .offset = length };
    const from = if (length < start) 0 else start;
    if (length == from) {
        return .{ .offset = from };
    }

    const gpa = std.heap.page_allocator;
    const buffer = gpa.alloc(u8, max_scan_bytes) catch return .{};
    defer gpa.free(buffer);
    var reader = file.reader(io, &.{});
    reader.seekTo(from) catch return .{};
    const len = reader.interface.readSliceShort(buffer) catch return .{};

    const result = scan(buffer[0..len], session, title_buffer);
    // A line longer than the whole window can never complete: skip it.
    const consumed = if (result.consumed == 0 and len == buffer.len) len else result.consumed;
    return .{
        .offset = from + consumed,
        .title = result.title,
    };
}

const Scan = struct {
    /// Bytes fully handled: up to and including the last newline, so a
    /// partial trailing line is read again once complete.
    consumed: usize,
    /// The last name written for the session, copied into the caller's
    /// buffer and cut to the title bound. Empty means the name was cleared.
    title: ?[]const u8,
};

const TitleLine = struct {
    customTitle: []const u8 = "",
    sessionId: []const u8 = "",
};
