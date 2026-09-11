const std = @import("std");
const tlsz = @import("tls");
const End = @import("End.zig");
/// One terminated connection: a TLS server towards the child and a TLS client
/// towards the real host.
///
/// Heap allocated and initialised in place. `tlsz.Connection` holds pointers
/// into the reader and writer next to it, which hold pointers into the buffers
/// next to those, so a Session must never be copied or moved after `intercept`.
const Session = @This();

io: std.Io,
gpa: std.mem.Allocator,
rng_source: std.Random.IoSource,
auth: tlsz.config.CertKeyPair,
child: End,
origin: End,

pub const Side = enum { child, origin };
pub const Protocol = enum { http11, h2 };

pub fn deinit(self: *Session) void {
    // Best effort close_notify; a peer that has already gone away makes
    // this fail, which is not worth reporting.
    self.child.conn.close() catch {};
    self.origin.conn.close() catch {};
    self.auth.deinit(self.gpa);
    self.gpa.destroy(self);
}

/// Reads cleartext into `buf`. Null on end of stream or error, which the
/// relays treat identically: the conversation is over either way.
pub fn read(self: *Session, side: Side, buf: []u8) ?usize {
    const n = self.end(side).conn.read(buf) catch return null;
    if (n == 0) {
        return null;
    }
    return n;
}

/// Encrypts and sends `bytes`. Each record is flushed as it is produced, so
/// a streaming response (SSE, chunked) still arrives token by token.
pub fn writeAll(self: *Session, side: Side, bytes: []const u8) bool {
    self.end(side).conn.writeAll(bytes) catch return false;
    return true;
}

/// Half-closes one side so a peer blocked reading it gives up.
///
/// Without this a full-duplex relay outlives the conversation: the client
/// goes away, but the origin holds a keep-alive connection open and the
/// direction reading it blocks until a timeout that may never come.
pub fn halfClose(self: *Session, side: Side) void {
    self.end(side).stream.shutdown(self.io, .both) catch {};
}

/// Which protocol the two ends settled on. Both agree by construction: the
/// origin is offered exactly what the child negotiated.
pub fn negotiated(self: *Session) Protocol {
    const selected = self.child.conn.alpn_protocol orelse return .http11;
    return if (std.mem.eql(u8, selected, "h2")) .h2 else .http11;
}

fn end(self: *Session, side: Side) *End {
    return switch (side) {
        .child => &self.child,
        .origin => &self.origin,
    };
}
