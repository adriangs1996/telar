const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

const tlsz = @import("tls");
const ca = @import("ca.zig");

// TLS termination, both ends.
//
// The proxy stops being a pipe here: it terminates the child's connection with a
// certificate it minted, opens its own connection to the real host, and sits in
// the middle holding plaintext.
//
// The stack is `tls.zig`, vendored — see `vendor/tls.vendor.json`. OpenSSL is
// still linked, but only `ca.zig` uses it now: minting X.509 is the one job with
// no Zig equivalent. Everything on the data path is Zig.
//
// Three things fall out of that swap and are worth naming, because each was a
// bug we had to find the hard way with OpenSSL:
//
//   * `Io` owns the sockets, so there is no non-blocking/blocking mismatch to
//     paper over. The old `makeBlocking` fcntl hack is gone.
//   * The upstream trust store comes from `std.crypto.Certificate.Bundle`, which
//     reads the platform's roots directly and never consults `SSL_CERT_FILE`.
//     The self-poisoning failure — verifying the real origin against our own CA
//     because we exported that variable for the child — cannot happen here.
//   * ALPN is a list in the options rather than a callback that can lie. The
//     protocol still has to be mirrored, for the same reason as before.

/// Named per stage: which end refused is the whole diagnosis. A failure towards
/// the child means it does not trust our CA; towards the origin it usually means
/// certificate pinning or a broken trust store.
pub const Error = error{
    ContextFailed,
    UpstreamHandshakeFailed,
    DownstreamHandshakeFailed,
    MintFailed,
};

/// What the child is offered, in preference order.
///
/// Static, not a stack local: a negotiated protocol is returned as a slice
/// *into this list*, and it has to stay valid for the life of the connection.
const alpn_offer = [_][]const u8{ "h2", "http/1.1" };
const alpn_h2_only = [_][]const u8{"h2"};
const alpn_http11_only = [_][]const u8{"http/1.1"};

/// The trust store used to verify real origins, loaded once per process.
///
/// Rescanning the platform roots costs a few milliseconds and an allocation per
/// connection, and every connection wants the same answer.
pub const Roots = struct {
    bundle: tlsz.config.cert.Bundle,

    pub fn load(io: Io, gpa: std.mem.Allocator) !Roots {
        return .{ .bundle = try tlsz.config.cert.fromSystem(gpa, io) };
    }

    pub fn deinit(self: *Roots, gpa: std.mem.Allocator) void {
        self.bundle.deinit(gpa);
    }
};

/// One terminated connection: a TLS server towards the child and a TLS client
/// towards the real host.
///
/// Heap allocated and initialised in place. `tlsz.Connection` holds pointers
/// into the reader and writer next to it, which hold pointers into the buffers
/// next to those, so a Session must never be copied or moved after `intercept`.
pub const Session = struct {
    io: Io,
    gpa: std.mem.Allocator,
    rng_source: std.Random.IoSource,
    auth: tlsz.config.CertKeyPair,
    child: End,
    origin: End,

    const End = struct {
        stream: net.Stream,
        in_buf: [tlsz.input_buffer_len]u8 = undefined,
        out_buf: [tlsz.output_buffer_len]u8 = undefined,
        reader: net.Stream.Reader = undefined,
        writer: net.Stream.Writer = undefined,
        conn: tlsz.Connection = undefined,

        fn wire(self: *End, io: Io) void {
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
};

/// Handshakes both ends. `host` is the CONNECT target, used both to mint the
/// certificate the child will check and to verify the real server. `cause`
/// receives the underlying failure, which the returned `Error` only categorises.
pub const InterceptResources = struct {
    io: Io,
    allocator: std.mem.Allocator,
    authority: ca.Authority,
    roots: Roots,
};

pub const InterceptConnection = struct {
    host: []const u8,
    child: net.Stream,
    origin: net.Stream,
};

pub fn intercept(resources: InterceptResources, connection: InterceptConnection, cause: *anyerror) Error!*Session {
    const io = resources.io;
    const gpa = resources.allocator;
    const roots = resources.roots;
    const host = connection.host;
    const child = connection.child;
    const origin = connection.origin;
    cause.* = error.Unknown;

    const self = gpa.create(Session) catch return error.ContextFailed;
    errdefer gpa.destroy(self);

    self.* = .{
        .io = io,
        .gpa = gpa,
        .rng_source = .{ .io = io },
        .auth = try mintAuth(resources, host, cause),
        .child = .{ .stream = child },
        .origin = .{ .stream = origin },
    };
    errdefer self.auth.deinit(gpa);

    self.child.wire(io);
    self.origin.wire(io);

    // ---- towards the real host first, carrying the child's own ALPN list.
    //
    // Answering the child first is the tempting order, and it is what this did
    // until an origin that declines ALPN altogether turned up: the child had
    // already been told `h2`, so the relay pushed frames at a listener that had
    // fallen back to HTTP/1.1, and got a 400 for its trouble. The origin is the
    // party with no room to move, so the origin decides.
    //
    // Reading the offer out of the ClientHello instead of answering it keeps the
    // earlier failure fixed too: the child is never offered anything the origin
    // has not already accepted, so the two ends cannot end up disagreeing.
    const offer = peekAlpnOffer(&self.child.reader.interface);

    self.origin.conn = tlsz.client(
        &self.origin.reader.interface,
        &self.origin.writer.interface,
        .{
            .host = host,
            .root_ca = roots.bundle,
            .now = Io.Clock.real.now(io),
            .rng = self.rng_source.interface(),
            .alpn_protocols = offer,
        },
    ) catch |err| {
        cause.* = self.origin.concrete(err);
        return error.UpstreamHandshakeFailed;
    };

    // ---- and now the child, offered exactly the one protocol the origin
    // agreed to. A null selection means the origin declined ALPN, so the child
    // is offered none either and both ends fall back to HTTP/1.1 together.
    self.child.conn = tlsz.server(
        &self.child.reader.interface,
        &self.child.writer.interface,
        .{
            .auth = &self.auth,
            .now = Io.Clock.real.now(io),
            .rng = self.rng_source.interface(),
            .alpn_protocols = mirroredAlpn(self.origin.conn.alpn_protocol),
            // The child does not get to pick the version the way it picks the
            // protocol: whatever it can do, we serve. A client that tops out at
            // TLS 1.2 is one this proxy could not terminate at all before.
            .cipher_suites_tls12 = &tlsz.config.cipher_suites.tls12_secure,
        },
    ) catch |err| {
        cause.* = self.child.concrete(err);
        return error.DownstreamHandshakeFailed;
    };

    return self;
}

/// The single protocol the origin settled on. Offering the child anything else
/// would let the two ends disagree.
fn mirroredAlpn(selected: ?[]const u8) []const []const u8 {
    const protocol = selected orelse return &.{};
    if (std.mem.eql(u8, protocol, "h2")) {
        return &alpn_h2_only;
    }
    return &alpn_http11_only;
}

/// A plain-language note for the failures whose error name does not explain
/// itself. `TlsNoSupportedCiphers` in particular reads like a configuration
/// mistake and is actually a capability gap: the vendored server implements
/// TLS 1.3 only, so a child whose stack tops out at 1.2 cannot be intercepted
/// at all. Naming that in the timeline saves rediscovering it.
pub fn explain(cause: anyerror) ?[]const u8 {
    return switch (cause) {
        error.TlsNoSupportedCiphers => "child offered no cipher suite we serve; only ECDHE with AES-GCM or ChaCha20 is accepted",
        error.SocketUnconnected, error.ConnectionResetByPeer => "child abandoned the connection before the handshake finished",
        else => null,
    };
}

/// Reads the child's ALPN list out of its ClientHello without consuming it.
///
/// `peek` fills the reader and hands back a view into its buffer, so the
/// handshake that runs afterwards still sees the record untouched. Anything
/// unparseable falls back to offering both, which is what this did before it
/// looked at all.
fn peekAlpnOffer(reader: *Io.Reader) []const []const u8 {
    return parseAlpnOffer(reader) catch &alpn_offer;
}

fn parseAlpnOffer(reader: *Io.Reader) !([]const []const u8) {
    const header = try reader.peek(tls_record_header_len);
    if (header[0] != handshake_record) {
        return error.NotAHandshake;
    }

    // Widened before it is added to, and bounded before it is asked for. This
    // length is the first attacker-controlled number in the connection: as a
    // u16 it overflows the header addition, and asking a reader to fill more
    // than its buffer holds is an assertion failure, not an error. A plaintext
    // TLS record cannot exceed 2^14 anyway.
    const record_len: usize = std.mem.readInt(u16, header[3..5], .big);
    if (record_len > max_plaintext_record_len) {
        return error.RecordTooLarge;
    }

    const record = try reader.peek(tls_record_header_len + record_len);
    var cursor: Cursor = .{ .bytes = record[tls_record_header_len..] };

    if (try cursor.byte() != client_hello) {
        return error.NotAClientHello;
    }
    _ = try cursor.take(3); // handshake length
    _ = try cursor.take(2); // legacy version
    _ = try cursor.take(32); // random
    _ = try cursor.take(try cursor.byte()); // legacy session id
    _ = try cursor.take(try cursor.big16()); // cipher suites
    _ = try cursor.take(try cursor.byte()); // legacy compression methods

    var extensions: Cursor = .{ .bytes = try cursor.take(try cursor.big16()) };
    while (extensions.left() > 0) {
        const kind = try extensions.big16();
        const body = try extensions.take(try extensions.big16());
        if (kind != alpn_extension) {
            continue;
        }

        var names: Cursor = .{ .bytes = body };
        _ = try names.big16(); // list length, already bounded by the extension
        var h2 = false;
        var http11 = false;
        while (names.left() > 0) {
            const name = try names.take(try names.byte());
            if (std.mem.eql(u8, name, "h2")) {
                h2 = true;
            }
            if (std.mem.eql(u8, name, "http/1.1")) {
                http11 = true;
            }
        }
        if (h2 and http11) {
            return &alpn_offer;
        }
        if (h2) {
            return &alpn_h2_only;
        }
        if (http11) {
            return &alpn_http11_only;
        }
        // An ALPN extension listing only protocols this relay cannot read.
        // Forwarding it would let the origin pick one of them.
        return &.{};
    }
    // No ALPN extension at all: mirror the silence rather than inventing one.
    return &.{};
}

const tls_record_header_len = 5;
const max_plaintext_record_len = 1 << 14;
const handshake_record: u8 = 0x16;
const client_hello: u8 = 0x01;
const alpn_extension: u16 = 16;

/// Bounds-checked forward reader over a byte slice. Every length in a
/// ClientHello arrives from the wire, so every step has to be able to fail.
const Cursor = struct {
    bytes: []const u8,
    idx: usize = 0,

    fn left(self: Cursor) usize {
        return self.bytes.len - self.idx;
    }

    fn take(self: *Cursor, n: usize) ![]const u8 {
        if (self.left() < n) {
            return error.Truncated;
        }
        defer self.idx += n;
        return self.bytes[self.idx..][0..n];
    }

    fn byte(self: *Cursor) !u8 {
        return (try self.take(1))[0];
    }

    fn big16(self: *Cursor) !u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .big);
    }
};

/// Mints a leaf for `host` and turns it into something a Zig TLS stack accepts.
///
/// The chain is leaf then CA: a client that pinned only the root still needs the
/// issuer to build a path. The PEM never touches the filesystem, so the leaf's
/// private key exists only in this process.
fn mintAuth(resources: InterceptResources, host: []const u8, cause: *anyerror) Error!tlsz.config.CertKeyPair {
    const io = resources.io;
    const gpa = resources.allocator;
    const authority = resources.authority;
    const leaf = authority.mint(io, host) catch |err| {
        cause.* = err;
        return error.MintFailed;
    };

    var chain_buf: [8 * 1024]u8 = undefined;
    var key_buf: [4 * 1024]u8 = undefined;

    const pair = blk: {
        const leaf_pem = leaf.certPem(&chain_buf) catch |err| break :blk err;
        const ca_pem = authority.pair.certPem(chain_buf[leaf_pem.len..]) catch |err| break :blk err;
        const key_pem = leaf.keyPem(&key_buf) catch |err| break :blk err;
        break :blk tlsz.config.CertKeyPair.fromSlice(
            gpa,
            io,
            chain_buf[0 .. leaf_pem.len + ca_pem.len],
            key_pem,
        );
    } catch |err| {
        cause.* = err;
        return error.MintFailed;
    };
    return pair;
}

// ---------------------------------------------------------------------------
// Tests
//
// The ClientHello parser reads lengths straight off the wire before any
// handshake has authenticated anything, so every field it trusts is a field an
// attacker controls. These cover what it must extract and, more importantly,
// that malformed input falls back rather than reading past the buffer.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Builds a ClientHello carrying `protocols` as its ALPN list, or no ALPN
/// extension at all when the list is empty.
fn fakeClientHello(out: []u8, protocols: []const []const u8) []u8 {
    var w = std.Io.Writer.fixed(out);

    var alpn: [128]u8 = undefined;
    var names = std.Io.Writer.fixed(&alpn);
    for (protocols) |name| {
        names.writeByte(@intCast(name.len)) catch unreachable;
        names.writeAll(name) catch unreachable;
    }
    const name_list = names.buffered();

    var exts: [160]u8 = undefined;
    var ext_w = std.Io.Writer.fixed(&exts);
    if (protocols.len > 0) {
        ext_w.writeInt(u16, alpn_extension, .big) catch unreachable;
        ext_w.writeInt(u16, @intCast(name_list.len + 2), .big) catch unreachable;
        ext_w.writeInt(u16, @intCast(name_list.len), .big) catch unreachable;
        ext_w.writeAll(name_list) catch unreachable;
    }
    const extensions = ext_w.buffered();

    // handshake body: version, random, session id, suites, compression, exts
    const body_len = 2 + 32 + 1 + (2 + 2) + (1 + 1) + 2 + extensions.len;
    const record_len = 1 + 3 + body_len;

    w.writeByte(handshake_record) catch unreachable;
    w.writeAll(&.{ 0x03, 0x01 }) catch unreachable;
    w.writeInt(u16, @intCast(record_len), .big) catch unreachable;

    w.writeByte(client_hello) catch unreachable;
    w.writeInt(u24, @intCast(body_len), .big) catch unreachable;
    w.writeAll(&.{ 0x03, 0x03 }) catch unreachable;
    w.writeAll(&[_]u8{0} ** 32) catch unreachable;
    w.writeByte(0) catch unreachable; // empty session id
    w.writeInt(u16, 2, .big) catch unreachable; // one cipher suite
    w.writeAll(&.{ 0x13, 0x01 }) catch unreachable;
    w.writeByte(1) catch unreachable; // one compression method
    w.writeByte(0) catch unreachable;
    w.writeInt(u16, @intCast(extensions.len), .big) catch unreachable;
    w.writeAll(extensions) catch unreachable;

    return w.buffered();
}

fn offerOf(hello: []const u8) []const []const u8 {
    var reader = std.Io.Reader.fixed(hello);
    return peekAlpnOffer(&reader);
}

test "the child's ALPN list is read out of its ClientHello" {
    var buf: [512]u8 = undefined;

    const both = offerOf(fakeClientHello(&buf, &.{ "h2", "http/1.1" }));
    try testing.expectEqual(@as(usize, 2), both.len);
    try testing.expectEqualStrings("h2", both[0]);
    try testing.expectEqualStrings("http/1.1", both[1]);

    const h2 = offerOf(fakeClientHello(&buf, &.{"h2"}));
    try testing.expectEqual(@as(usize, 1), h2.len);
    try testing.expectEqualStrings("h2", h2[0]);

    const http11 = offerOf(fakeClientHello(&buf, &.{"http/1.1"}));
    try testing.expectEqual(@as(usize, 1), http11.len);
    try testing.expectEqualStrings("http/1.1", http11[0]);
}

test "a client that sent no ALPN is not given one" {
    // Inventing an offer here would make the origin pick a protocol the child
    // never asked for, and the child would then be told about it.
    var buf: [512]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), offerOf(fakeClientHello(&buf, &.{})).len);
}

test "protocols this relay cannot read are not forwarded" {
    var buf: [512]u8 = undefined;
    const hello = fakeClientHello(&buf, &.{ "h3", "spdy/3.1" });
    try testing.expectEqual(@as(usize, 0), offerOf(hello).len);
}

test "the ordering the child asked for does not leak through" {
    // Preference is ours to decide once both ends can do both: the offer list
    // is normalised, so a child asking for http/1.1 first still gets h2 when
    // the origin supports it.
    var buf: [512]u8 = undefined;
    const reversed = offerOf(fakeClientHello(&buf, &.{ "http/1.1", "h2" }));
    try testing.expectEqualStrings("h2", reversed[0]);
}

test "malformed input falls back instead of reading past the buffer" {
    var buf: [512]u8 = undefined;
    const hello = fakeClientHello(&buf, &.{ "h2", "http/1.1" });

    // Truncated at every length prefix the parser trusts.
    var cut: usize = 5;
    while (cut < hello.len) : (cut += 1) {
        const offer = offerOf(hello[0..cut]);
        try testing.expect(offer.len == 2); // the both-protocols fallback
    }

    // Not a handshake record at all.
    try testing.expectEqual(@as(usize, 2), offerOf("GET / HTTP/1.1\r\n\r\n").len);

    // A length field claiming far more than the record holds.
    var lying: [512]u8 = undefined;
    @memcpy(lying[0..hello.len], hello);
    std.mem.writeInt(u16, lying[3..5], 0xffff, .big);
    try testing.expectEqual(@as(usize, 2), offerOf(lying[0..hello.len]).len);
}

test "peeking leaves the ClientHello for the handshake to read" {
    // The whole approach depends on this: the bytes are inspected in place and
    // the TLS server still gets a stream that starts at the record header.
    var buf: [512]u8 = undefined;
    const hello = fakeClientHello(&buf, &.{"h2"});

    var reader = std.Io.Reader.fixed(hello);
    _ = peekAlpnOffer(&reader);

    const rest = reader.buffered();
    try testing.expectEqual(hello.len, rest.len);
    try testing.expectEqual(handshake_record, rest[0]);
}
