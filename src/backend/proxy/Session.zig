const std = @import("std");
const tlsz = @import("tls");
const End = @import("End.zig");
/// Heap allocated because TLS connections borrow the adjacent reader/writer
/// buffers and must never move after initialization.
const Session = @This();

io: std.Io,
gpa: std.mem.Allocator,
random: std.Random.IoSource,
auth: tlsz.config.CertKeyPair,
child: End,
origin: End,

pub const Side = enum { child, origin };
pub const Protocol = enum { http11, h2 };

pub fn deinit(self: *Session) void {
    const gpa = self.gpa;
    self.child.connection.close() catch {};
    self.origin.connection.close() catch {};
    self.auth.deinit(gpa);
    std.crypto.secureZero(u8, std.mem.asBytes(self));
    gpa.destroy(self);
}

pub fn read(self: *Session, side: Side, buffer: []u8) ?usize {
    const len = self.end(side).connection.read(buffer) catch return null;
    return if (len == 0) null else len;
}

pub fn writeAll(self: *Session, side: Side, bytes: []const u8) bool {
    self.end(side).connection.writeAll(bytes) catch return false;
    return true;
}

pub fn halfClose(self: *Session, side: Side) void {
    // Each relay owns only the send direction of its destination. Closing
    // both directions here races the opposite relay and can truncate h2
    // or upgraded responses after the request side reaches EOF.
    self.end(side).stream.shutdown(self.io, .send) catch {};
}

pub fn negotiated(self: *const Session) Protocol {
    const selected = self.child.connection.alpn_protocol orelse return .http11;
    return if (std.mem.eql(u8, selected, "h2")) .h2 else .http11;
}

fn end(self: *Session, side: Side) *End {
    return switch (side) {
        .child => &self.child,
        .origin => &self.origin,
    };
}
