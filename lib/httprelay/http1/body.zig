//! Streaming relay for HTTP/1.1 message bodies.
//!
//! The relay preserves wire bytes exactly. It uses the framing already derived
//! from the head and keeps all buffers fixed-size.

const std = @import("std");
const localca = @import("localca");
const Session = localca.Session;
const observer_hooks = @import("../observer_hooks.zig");
const FramingLine = @import("FramingLine.zig").FramingLine;

/// The longest chunk-size line, extensions included.
pub const max_chunk_line_bytes = 1024;
/// The longest trailer field line: a header field line as long as common
/// servers accept.
pub const max_trailer_line_bytes = 8 * 1024;

pub const Route = @import("Route.zig");

/// Relays one body according to its parsed route and reports forwarded
/// fragments without giving the observer control over traffic.
///
/// The observer's `observe(Fragment)` method runs only after the corresponding
/// bytes have been written. Its return value, if any, is ignored. An observer
/// that declares `lineTooLong(FramingLine)` hears when a chunk-size or
/// trailer line passes its bound, which ends the body.
///
/// ```zig
/// const route: Route = .{ .from = .origin, .to = .child, .framing = .chunked };
/// const forwarded = relay(session, route, &observer);
/// ```
pub fn relay(session: anytype, route: Route, observer: anytype) bool {
    const direction: Direction = .{ .from = route.from, .to = route.to };

    return switch (route.framing) {
        .none => true,
        .content_length => |len| relayExact(session, .{
            .direction = direction,
            .count = len,
            .payload = true,
        }, observer),
        .chunked => relayChunked(session, direction, observer),
        .until_close => relayUntilClose(session, direction, observer),
    };
}

fn relayUntilClose(session: anytype, direction: Direction, observer: anytype) bool {
    var buffer: [16 * 1024]u8 = undefined;

    while (session.read(direction.from, &buffer)) |len| {
        if (!session.writeAll(direction.to, buffer[0..len])) {
            return false;
        }

        observer.observe(.{ .payload = buffer[0..len] });
    }

    return true;
}

fn relayExact(session: anytype, exact: Exact, observer: anytype) bool {
    var left = exact.count;
    var buffer: [16 * 1024]u8 = undefined;

    while (left != 0) {
        const len = session.read(exact.direction.from, buffer[0..@min(left, buffer.len)]) orelse return false;

        if (!session.writeAll(exact.direction.to, buffer[0..len])) {
            return false;
        }

        observer.observe(.{
            .payload = if (exact.payload) buffer[0..len] else "",
        });
        left -= len;
    }

    return true;
}

fn relayChunked(session: anytype, direction: Direction, observer: anytype) bool {
    var line: [max_chunk_line_bytes]u8 = undefined;

    while (true) {
        const line_len = relayLine(session, direction, .{
            .buffer = &line,
            .kind = .chunk_size,
        }, observer) orelse return false;
        const trimmed = std.mem.trim(u8, line[0..line_len], " \t\r\n");
        const extension = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
        const chunk_len = std.fmt.parseInt(usize, trimmed[0..extension], 16) catch return false;

        if (chunk_len == 0) {
            return relayTrailers(session, direction, observer);
        }

        if (!relayExact(session, .{
            .direction = direction,
            .count = chunk_len,
            .payload = true,
        }, observer)) {
            return false;
        }

        if (!relayExact(session, .{
            .direction = direction,
            .count = 2,
            .payload = false,
        }, observer)) {
            return false;
        }
    }
}

fn relayTrailers(session: anytype, direction: Direction, observer: anytype) bool {
    var line: [max_trailer_line_bytes]u8 = undefined;

    while (true) {
        const len = relayLine(session, direction, .{
            .buffer = &line,
            .kind = .trailer,
        }, observer) orelse return false;

        if (len == 2 and std.mem.eql(u8, line[0..2], "\r\n")) {
            return true;
        }
    }
}

fn relayLine(session: anytype, direction: Direction, line: Line, observer: anytype) ?usize {
    const buffer = line.buffer;
    var len: usize = 0;

    while (len < buffer.len) {
        const read_len = session.read(direction.from, buffer[len..][0..1]) orelse {
            if (len != 0) {
                _ = session.writeAll(direction.to, buffer[0..len]);
            }

            return null;
        };

        if (read_len != 1) {
            return null;
        }

        len += 1;

        if (len >= 2 and std.mem.eql(u8, buffer[len - 2 .. len], "\r\n")) {
            return if (session.writeAll(direction.to, buffer[0..len])) len else null;
        }
    }

    // Preserve the consumed prefix even when framing fails at its bound.
    _ = session.writeAll(direction.to, buffer[0..len]);
    if (comptime observer_hooks.declares(@TypeOf(observer), "lineTooLong")) {
        observer.lineTooLong(line.kind);
    }

    return null;
}

const Exact = struct {
    direction: Direction,
    count: usize,
    payload: bool,
};

/// One framing line's buffer, which bounds it, and what the line is.
const Line = struct {
    buffer: []u8,
    kind: FramingLine,
};

const Direction = struct {
    from: Session.Side,
    to: Session.Side,
};
