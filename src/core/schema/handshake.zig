//! Stable handshake used before either peer decodes versioned messages.

const std = @import("std");

pub const Version = u16;
pub const current_version: Version = 2;
pub const supported_versions = VersionRange{
    .minimum = current_version,
    .maximum = current_version,
};

pub const magic: [8]u8 = "TELARIPC".*;
pub const wire_revision: u8 = 1;

const header_size = magic.len + 2;
pub const client_hello_size = header_size + 4;
pub const server_accept_size = header_size + 2;
pub const server_reject_size = header_size + 5;
pub const max_message_size = server_reject_size;

pub const Tag = enum(u8) {
    client_hello = 1,
    server_accept = 2,
    server_reject = 3,
};

pub const RejectReason = enum(u8) {
    incompatible_versions = 1,
};

pub const VersionRange = struct {
    minimum: Version,
    maximum: Version,

    pub fn isValid(range: VersionRange) bool {
        return range.minimum != 0 and range.minimum <= range.maximum;
    }

    pub fn contains(range: VersionRange, version: Version) bool {
        return range.isValid() and version >= range.minimum and version <= range.maximum;
    }
};

pub const ClientHello = struct {
    versions: VersionRange = supported_versions,
};

pub const ServerAccept = struct {
    version: Version,
};

pub const ServerReject = struct {
    reason: RejectReason,
    supported_versions: VersionRange,
};

pub const ServerResponse = union(enum) {
    accepted: ServerAccept,
    rejected: ServerReject,
};

pub const EncodeError = error{
    BufferTooSmall,
    InvalidVersionRange,
    InvalidSelectedVersion,
};

pub const DecodeError = error{
    InvalidLength,
    InvalidMagic,
    UnsupportedWireRevision,
    UnknownMessage,
    UnexpectedMessage,
    InvalidVersionRange,
    InvalidSelectedVersion,
    UnknownRejectReason,
};

pub fn negotiate(client: VersionRange, server: VersionRange) error{InvalidVersionRange}!ServerResponse {
    if (!client.isValid() or !server.isValid()) return error.InvalidVersionRange;

    const minimum = @max(client.minimum, server.minimum);
    const maximum = @min(client.maximum, server.maximum);
    if (minimum <= maximum) {
        return .{ .accepted = .{ .version = maximum } };
    }
    return .{ .rejected = .{
        .reason = .incompatible_versions,
        .supported_versions = server,
    } };
}

pub fn encodeClientHello(buffer: []u8, hello: ClientHello) EncodeError![]const u8 {
    if (!hello.versions.isValid()) return error.InvalidVersionRange;
    if (buffer.len < client_hello_size) return error.BufferTooSmall;

    writeHeader(buffer, .client_hello);
    std.mem.writeInt(Version, buffer[header_size..][0..2], hello.versions.minimum, .little);
    std.mem.writeInt(Version, buffer[header_size + 2 ..][0..2], hello.versions.maximum, .little);
    return buffer[0..client_hello_size];
}

pub fn decodeClientHello(payload: []const u8) DecodeError!ClientHello {
    const tag = try decodeHeader(payload);
    if (tag != .client_hello) return error.UnexpectedMessage;
    if (payload.len != client_hello_size) return error.InvalidLength;

    const versions = VersionRange{
        .minimum = std.mem.readInt(Version, payload[header_size..][0..2], .little),
        .maximum = std.mem.readInt(Version, payload[header_size + 2 ..][0..2], .little),
    };
    if (!versions.isValid()) return error.InvalidVersionRange;
    return .{ .versions = versions };
}

pub fn encodeServerResponse(buffer: []u8, response: ServerResponse) EncodeError![]const u8 {
    return switch (response) {
        .accepted => |accepted| encodeServerAccept(buffer, accepted),
        .rejected => |rejected| encodeServerReject(buffer, rejected),
    };
}

pub fn decodeServerResponse(payload: []const u8) DecodeError!ServerResponse {
    return switch (try decodeHeader(payload)) {
        .server_accept => .{ .accepted = try decodeServerAccept(payload) },
        .server_reject => .{ .rejected = try decodeServerReject(payload) },
        .client_hello => error.UnexpectedMessage,
    };
}

fn encodeServerAccept(buffer: []u8, accepted: ServerAccept) EncodeError![]const u8 {
    if (accepted.version == 0) return error.InvalidSelectedVersion;
    if (buffer.len < server_accept_size) return error.BufferTooSmall;

    writeHeader(buffer, .server_accept);
    std.mem.writeInt(Version, buffer[header_size..][0..2], accepted.version, .little);
    return buffer[0..server_accept_size];
}

fn decodeServerAccept(payload: []const u8) DecodeError!ServerAccept {
    if (payload.len != server_accept_size) return error.InvalidLength;
    const version = std.mem.readInt(Version, payload[header_size..][0..2], .little);
    if (version == 0) return error.InvalidSelectedVersion;
    return .{ .version = version };
}

fn encodeServerReject(buffer: []u8, rejected: ServerReject) EncodeError![]const u8 {
    if (!rejected.supported_versions.isValid()) return error.InvalidVersionRange;
    if (buffer.len < server_reject_size) return error.BufferTooSmall;

    writeHeader(buffer, .server_reject);
    buffer[header_size] = @intFromEnum(rejected.reason);
    std.mem.writeInt(
        Version,
        buffer[header_size + 1 ..][0..2],
        rejected.supported_versions.minimum,
        .little,
    );
    std.mem.writeInt(
        Version,
        buffer[header_size + 3 ..][0..2],
        rejected.supported_versions.maximum,
        .little,
    );
    return buffer[0..server_reject_size];
}

fn decodeServerReject(payload: []const u8) DecodeError!ServerReject {
    if (payload.len != server_reject_size) return error.InvalidLength;
    const reason: RejectReason = switch (payload[header_size]) {
        @intFromEnum(RejectReason.incompatible_versions) => .incompatible_versions,
        else => return error.UnknownRejectReason,
    };
    const versions = VersionRange{
        .minimum = std.mem.readInt(Version, payload[header_size + 1 ..][0..2], .little),
        .maximum = std.mem.readInt(Version, payload[header_size + 3 ..][0..2], .little),
    };
    if (!versions.isValid()) return error.InvalidVersionRange;
    return .{ .reason = reason, .supported_versions = versions };
}

fn writeHeader(buffer: []u8, tag: Tag) void {
    std.mem.copyForwards(u8, buffer[0..magic.len], &magic);
    buffer[magic.len] = wire_revision;
    buffer[magic.len + 1] = @intFromEnum(tag);
}

fn decodeHeader(payload: []const u8) DecodeError!Tag {
    if (payload.len < header_size) return error.InvalidLength;
    if (!std.mem.eql(u8, payload[0..magic.len], &magic)) return error.InvalidMagic;
    if (payload[magic.len] != wire_revision) return error.UnsupportedWireRevision;
    return switch (payload[magic.len + 1]) {
        @intFromEnum(Tag.client_hello) => .client_hello,
        @intFromEnum(Tag.server_accept) => .server_accept,
        @intFromEnum(Tag.server_reject) => .server_reject,
        else => error.UnknownMessage,
    };
}

test "client hello has a stable byte representation" {
    var buffer: [client_hello_size]u8 = undefined;
    const encoded = try encodeClientHello(&buffer, .{ .versions = .{
        .minimum = 1,
        .maximum = 3,
    } });

    try std.testing.expectEqualSlices(u8, &magic, encoded[0..magic.len]);
    try std.testing.expectEqual(wire_revision, encoded[magic.len]);
    try std.testing.expectEqual(@intFromEnum(Tag.client_hello), encoded[magic.len + 1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 3, 0 }, encoded[header_size..]);

    const decoded = try decodeClientHello(encoded);
    try std.testing.expectEqual(@as(Version, 1), decoded.versions.minimum);
    try std.testing.expectEqual(@as(Version, 3), decoded.versions.maximum);
}

test "negotiation selects the highest shared version" {
    const response = try negotiate(
        .{ .minimum = 1, .maximum = 4 },
        .{ .minimum = 2, .maximum = 3 },
    );
    try std.testing.expectEqual(@as(Version, 3), response.accepted.version);
}

test "negotiation reports the server range when versions do not overlap" {
    const server = VersionRange{ .minimum = 1, .maximum = 2 };
    const response = try negotiate(.{ .minimum = 3, .maximum = 4 }, server);

    try std.testing.expectEqual(RejectReason.incompatible_versions, response.rejected.reason);
    try std.testing.expectEqual(server, response.rejected.supported_versions);
}

test "server responses round trip" {
    const responses = [_]ServerResponse{
        .{ .accepted = .{ .version = 1 } },
        .{ .rejected = .{
            .reason = .incompatible_versions,
            .supported_versions = supported_versions,
        } },
    };

    for (responses) |response| {
        var buffer: [max_message_size]u8 = undefined;
        const encoded = try encodeServerResponse(&buffer, response);
        const decoded = try decodeServerResponse(encoded);
        try std.testing.expectEqualDeep(response, decoded);
    }
}

test "malformed handshakes are rejected" {
    var buffer: [client_hello_size]u8 = undefined;
    const valid = try encodeClientHello(&buffer, .{});

    var wrong_magic = buffer;
    wrong_magic[0] = 'X';
    try std.testing.expectError(error.InvalidMagic, decodeClientHello(&wrong_magic));

    var wrong_revision = buffer;
    wrong_revision[magic.len] = wire_revision + 1;
    try std.testing.expectError(error.UnsupportedWireRevision, decodeClientHello(&wrong_revision));

    try std.testing.expectError(error.InvalidLength, decodeClientHello(valid[0 .. valid.len - 1]));
    try std.testing.expectError(
        error.InvalidVersionRange,
        encodeClientHello(&buffer, .{ .versions = .{ .minimum = 2, .maximum = 1 } }),
    );
}
