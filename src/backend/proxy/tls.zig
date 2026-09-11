//! TLS termination towards the child and the real origin.

const std = @import("std");
const tlsz = @import("tls");
const ca = @import("ca.zig");

pub const Io = std.Io;
pub const net = Io.net;

pub const Error = error{
    ContextFailed,
    UpstreamHandshakeFailed,
    DownstreamHandshakeFailed,
    MintFailed,
};

pub const InterceptOptions = @import("InterceptOptions.zig");

const alpn_offer = [_][]const u8{ "h2", "http/1.1" };
const alpn_h2_only = [_][]const u8{"h2"};
const alpn_http11_only = [_][]const u8{"http/1.1"};

pub const Roots = @import("Roots.zig");

pub const Session = @import("Session.zig");

/// Establishes verified TLS towards the origin and mirrored TLS towards the
/// child. Every failure releases all partially initialized TLS state; the
/// caller retains ownership of both streams.
///
/// ```zig
/// const session = try intercept(options);
/// defer session.deinit();
/// ```
pub fn intercept(options: InterceptOptions) Error!*Session {
    const session = options.gpa.create(Session) catch return error.ContextFailed;
    errdefer {
        std.crypto.secureZero(u8, std.mem.asBytes(session));
        options.gpa.destroy(session);
    }
    session.* = .{
        .io = options.io,
        .gpa = options.gpa,
        .random = .{ .io = options.io },
        .auth = try mintAuth(.{
            .io = options.io,
            .gpa = options.gpa,
            .authority = options.authority,
            .host = options.host,
        }),
        .child = .{ .stream = options.child },
        .origin = .{ .stream = options.origin },
    };
    errdefer session.auth.deinit(options.gpa);
    session.child.wire(options.io);
    session.origin.wire(options.io);

    const offer = peekAlpnOffer(&session.child.reader.interface);
    session.origin.connection = tlsz.client(
        &session.origin.reader.interface,
        &session.origin.writer.interface,
        .{
            .host = options.host,
            .root_ca = options.roots.bundle,
            .now = Io.Clock.real.now(options.io),
            .rng = session.random.interface(),
            .alpn_protocols = offer,
        },
    ) catch {
        return error.UpstreamHandshakeFailed;
    };

    session.child.connection = tlsz.server(
        &session.child.reader.interface,
        &session.child.writer.interface,
        .{
            .auth = &session.auth,
            .now = Io.Clock.real.now(options.io),
            .rng = session.random.interface(),
            .alpn_protocols = mirroredAlpn(session.origin.connection.alpn_protocol),
            .cipher_suites_tls12 = &tlsz.config.cipher_suites.tls12_secure,
        },
    ) catch {
        return error.DownstreamHandshakeFailed;
    };
    return session;
}

fn mirroredAlpn(selected: ?[]const u8) []const []const u8 {
    const protocol = selected orelse return &.{};
    if (std.mem.eql(u8, protocol, "h2")) {
        return &alpn_h2_only;
    }
    return &alpn_http11_only;
}

fn peekAlpnOffer(reader: *Io.Reader) []const []const u8 {
    return parseAlpnOffer(reader) catch &alpn_offer;
}

const tls_record_header_len = 5;
const max_plaintext_record_len = 1 << 14;
const handshake_record: u8 = 0x16;
const client_hello: u8 = 0x01;
const alpn_extension: u16 = 16;

fn parseAlpnOffer(reader: *Io.Reader) ![]const []const u8 {
    const header = try reader.peek(tls_record_header_len);
    if (header[0] != handshake_record) {
        return error.NotAHandshake;
    }
    const record_len: usize = std.mem.readInt(u16, header[3..5], .big);
    if (record_len > max_plaintext_record_len) {
        return error.RecordTooLarge;
    }
    const record = try reader.peek(tls_record_header_len + record_len);
    var cursor: Cursor = .{ .bytes = record[tls_record_header_len..] };
    if (try cursor.byte() != client_hello) {
        return error.NotAClientHello;
    }
    _ = try cursor.take(3);
    _ = try cursor.take(2);
    _ = try cursor.take(32);
    _ = try cursor.take(try cursor.byte());
    _ = try cursor.take(try cursor.big16());
    _ = try cursor.take(try cursor.byte());

    var extensions: Cursor = .{ .bytes = try cursor.take(try cursor.big16()) };
    while (extensions.left() != 0) {
        const kind = try extensions.big16();
        const body = try extensions.take(try extensions.big16());
        if (kind != alpn_extension) {
            continue;
        }
        var names: Cursor = .{ .bytes = body };
        const declared = try names.big16();
        if (declared != names.left()) {
            return error.InvalidAlpnList;
        }
        var h2 = false;
        var http11 = false;
        while (names.left() != 0) {
            const name = try names.take(try names.byte());
            h2 = h2 or std.mem.eql(u8, name, "h2");
            http11 = http11 or std.mem.eql(u8, name, "http/1.1");
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
        return &.{};
    }
    return &.{};
}

const Cursor = @import("Cursor.zig");

const MintOptions = @import("MintOptions.zig");

fn mintAuth(options: MintOptions) Error!tlsz.config.CertKeyPair {
    var leaf = options.authority.mint(options.io, options.host) catch {
        return error.MintFailed;
    };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&leaf));
    var chain_buffer: [8 * 1024]u8 = undefined;
    var key_buffer: [4 * 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &key_buffer);
    const result = block: {
        const leaf_pem = leaf.certPem(&chain_buffer) catch |err| break :block err;
        const ca_pem = options.authority.pair.certPem(chain_buffer[leaf_pem.len..]) catch |err| break :block err;
        const key_pem = leaf.keyPem(&key_buffer) catch |err| break :block err;
        break :block tlsz.config.CertKeyPair.fromSlice(
            options.gpa,
            options.io,
            chain_buffer[0 .. leaf_pem.len + ca_pem.len],
            key_pem,
        );
    } catch {
        return error.MintFailed;
    };
    return result;
}

fn fakeClientHello(output: []u8, protocols: []const []const u8) []u8 {
    var writer = Io.Writer.fixed(output);
    var alpn_buffer: [128]u8 = undefined;
    var names = Io.Writer.fixed(&alpn_buffer);
    for (protocols) |name| {
        names.writeByte(@intCast(name.len)) catch unreachable;
        names.writeAll(name) catch unreachable;
    }
    const name_list = names.buffered();

    var extension_buffer: [160]u8 = undefined;
    var extensions = Io.Writer.fixed(&extension_buffer);
    if (protocols.len != 0) {
        extensions.writeInt(u16, alpn_extension, .big) catch unreachable;
        extensions.writeInt(u16, @intCast(name_list.len + 2), .big) catch unreachable;
        extensions.writeInt(u16, @intCast(name_list.len), .big) catch unreachable;
        extensions.writeAll(name_list) catch unreachable;
    }
    const extension_list = extensions.buffered();
    const body_len = 2 + 32 + 1 + (2 + 2) + (1 + 1) + 2 + extension_list.len;
    const record_len = 1 + 3 + body_len;

    writer.writeByte(handshake_record) catch unreachable;
    writer.writeAll(&.{ 0x03, 0x01 }) catch unreachable;
    writer.writeInt(u16, @intCast(record_len), .big) catch unreachable;
    writer.writeByte(client_hello) catch unreachable;
    writer.writeInt(u24, @intCast(body_len), .big) catch unreachable;
    writer.writeAll(&.{ 0x03, 0x03 }) catch unreachable;
    writer.writeAll(&[_]u8{0} ** 32) catch unreachable;
    writer.writeByte(0) catch unreachable;
    writer.writeInt(u16, 2, .big) catch unreachable;
    writer.writeAll(&.{ 0x13, 0x01 }) catch unreachable;
    writer.writeByte(1) catch unreachable;
    writer.writeByte(0) catch unreachable;
    writer.writeInt(u16, @intCast(extension_list.len), .big) catch unreachable;
    writer.writeAll(extension_list) catch unreachable;
    return writer.buffered();
}

fn offerOf(hello: []const u8) []const []const u8 {
    var reader = Io.Reader.fixed(hello);
    return peekAlpnOffer(&reader);
}

test "ALPN mirror never offers a second protocol" {
    try std.testing.expectEqual(@as(usize, 0), mirroredAlpn(null).len);
    try std.testing.expectEqualStrings("h2", mirroredAlpn("h2")[0]);
    try std.testing.expectEqualStrings("http/1.1", mirroredAlpn("http/1.1")[0]);
}

test "ClientHello ALPN is normalized to supported protocols" {
    var buffer: [512]u8 = undefined;
    const both = offerOf(fakeClientHello(&buffer, &.{ "http/1.1", "h2" }));
    try std.testing.expectEqual(@as(usize, 2), both.len);
    try std.testing.expectEqualStrings("h2", both[0]);
    try std.testing.expectEqualStrings("http/1.1", both[1]);

    const h2_only = offerOf(fakeClientHello(&buffer, &.{ "h3", "h2" }));
    try std.testing.expectEqual(@as(usize, 1), h2_only.len);
    try std.testing.expectEqualStrings("h2", h2_only[0]);
    try std.testing.expectEqual(@as(usize, 0), offerOf(fakeClientHello(&buffer, &.{})).len);
}

test "malformed ClientHello falls back without consuming bytes" {
    var buffer: [512]u8 = undefined;
    const hello = fakeClientHello(&buffer, &.{ "h2", "http/1.1" });
    for (tls_record_header_len..hello.len) |cut|
        try std.testing.expectEqual(@as(usize, 2), offerOf(hello[0..cut]).len);

    var reader = Io.Reader.fixed(hello);
    _ = peekAlpnOffer(&reader);
    try std.testing.expectEqualSlices(u8, hello, reader.buffered());
}
