/// Heap allocated because TLS connections borrow the adjacent reader/writer
/// buffers and must never move after initialization.
const Session = @This();
const source_namespace = @import("tls.zig");
const std = @import("std");
const tlsz = @import("tls");
io: source_namespace.Io,
gpa: std.mem.Allocator,
random: std.Random.IoSource,
auth: tlsz.config.CertKeyPair,
child: End,
origin: End,

const End = struct {
    stream: source_namespace.net.Stream,
    input_buffer: [tlsz.input_buffer_len]u8 = undefined,
    output_buffer: [tlsz.output_buffer_len]u8 = undefined,
    reader: source_namespace.net.Stream.Reader = undefined,
    writer: source_namespace.net.Stream.Writer = undefined,
    connection: tlsz.Connection = undefined,

    pub fn wire(endpoint: *End, io: source_namespace.Io) void {
        endpoint.reader = endpoint.stream.reader(io, &endpoint.input_buffer);
        endpoint.writer = endpoint.stream.writer(io, &endpoint.output_buffer);
    }
};

pub const Side = enum { child, origin };
pub const Protocol = enum { http11, h2 };

pub fn deinit(session: *Session) void {
    const gpa = session.gpa;
    session.child.connection.close() catch {};
    session.origin.connection.close() catch {};
    session.auth.deinit(gpa);
    std.crypto.secureZero(u8, std.mem.asBytes(session));
    gpa.destroy(session);
}

pub fn read(session: *Session, side: Side, buffer: []u8) ?usize {
    const len = session.end(side).connection.read(buffer) catch return null;
    return if (len == 0) null else len;
}

pub fn writeAll(session: *Session, side: Side, bytes: []const u8) bool {
    session.end(side).connection.writeAll(bytes) catch return false;
    return true;
}

pub fn halfClose(session: *Session, side: Side) void {
    // Each relay owns only the send direction of its destination. Closing
    // both directions here races the opposite relay and can truncate h2
    // or upgraded responses after the request side reaches EOF.
    session.end(side).stream.shutdown(session.io, .send) catch {};
}

pub fn negotiated(session: *const Session) Protocol {
    const selected = session.child.connection.alpn_protocol orelse return .http11;
    return if (std.mem.eql(u8, selected, "h2")) .h2 else .http11;
}

fn end(session: *Session, side: Side) *End {
    return switch (side) {
        .child => &session.child,
        .origin => &session.origin,
    };
}
