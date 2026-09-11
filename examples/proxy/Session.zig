/// One terminated connection: a TLS server towards the child and a TLS client
/// towards the real host.
///
/// Heap allocated and initialised in place. `tlsz.Connection` holds pointers
/// into the reader and writer next to it, which hold pointers into the buffers
/// next to those, so a Session must never be copied or moved after `intercept`.
const Session = @This();
const source_namespace = @import("tls.zig");
const std = @import("std");
const tlsz = @import("tls");
io: source_namespace.Io,
gpa: std.mem.Allocator,
rng_source: std.Random.IoSource,
auth: tlsz.config.CertKeyPair,
child: End,
origin: End,

const End = struct {
    stream: source_namespace.net.Stream,
    in_buf: [tlsz.input_buffer_len]u8 = undefined,
    out_buf: [tlsz.output_buffer_len]u8 = undefined,
    reader: source_namespace.net.Stream.Reader = undefined,
    writer: source_namespace.net.Stream.Writer = undefined,
    conn: tlsz.Connection = undefined,

    fn wire(self: *End, io: source_namespace.Io) void {
        self.reader = self.stream.reader(io, &self.in_buf);
        self.writer = self.stream.writer(io, &self.out_buf);
    }

    /// `Io.Reader`/`Io.Writer` collapse every transport failure into one
    /// error and stash the real one on the side. A handshake that died
    /// because the peer reset the socket and one that died because we sent
    /// something wrong are very different findings, so dig the real error
    /// back out before reporting.
    fn concrete(self: *End, err: anyerror) anyerror {
        if (err == error.WriteFailed) {
            return self.writer.err orelse err;
        }
        if (err == error.ReadFailed) {
            return self.reader.err orelse err;
        }
        return err;
    }
};

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
