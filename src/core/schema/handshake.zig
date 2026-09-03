//! Fixed handshake for Telar's single current schema.
//!
//! There is deliberately no version range yet. A client and runtime either
//! speak the exact same schema or refuse the connection. Historical decoders
//! belong here only once Telar promises rolling upgrades to users.

const std = @import("std");

pub const SchemaId = [8]u8;
/// Human-readable schema generation. Bump it on any breaking wire change so a
/// mismatch log can say which side is newer.
pub const schema_version: *const [2]u8 = "33";
/// Version prefix plus a fingerprint of the golden corpus in
/// `schema_contract_test.zig`. The test "the handshake fingerprint derives from the
/// golden corpus" recomputes the hash, so an encoding change cannot ship
/// without updating this constant. Do not keep the old decoder until rolling
/// upgrades become a supported product requirement.
pub const schema_id: SchemaId = (schema_version.* ++ "47f5a1".*);

pub const magic: [8]u8 = "TELARIPC".*;

const header_size = magic.len + 1;
pub const client_hello_size = header_size + schema_id.len;
pub const server_accept_size = header_size + schema_id.len;
pub const server_reject_size = header_size + 1 + schema_id.len;
pub const max_message_size = server_reject_size;

pub const Tag = enum(u8) {
    client_hello = 1,
    server_accept = 2,
    server_reject = 3,
};

pub const RejectReason = enum(u8) {
    incompatible_schema = 1,
};

pub const ClientHello = struct {
    schema: SchemaId = schema_id,
};

pub const ServerAccept = struct {
    schema: SchemaId,
};

pub const ServerReject = struct {
    reason: RejectReason,
    expected_schema: SchemaId,
};

pub const ServerResponse = union(enum) {
    accepted: ServerAccept,
    rejected: ServerReject,
};

pub const EncodeError = error{BufferTooSmall};

pub const DecodeError = error{
    InvalidLength,
    InvalidMagic,
    UnknownMessage,
    UnexpectedMessage,
    UnknownRejectReason,
};

pub fn negotiate(client: SchemaId, server: SchemaId) ServerResponse {
    if (std.mem.eql(u8, &client, &server))
        return .{ .accepted = .{ .schema = server } };
    return .{ .rejected = .{
        .reason = .incompatible_schema,
        .expected_schema = server,
    } };
}

pub fn encodeClientHello(buffer: []u8, hello: ClientHello) EncodeError![]const u8 {
    if (buffer.len < client_hello_size) return error.BufferTooSmall;
    writeHeader(buffer, .client_hello);
    @memcpy(buffer[header_size..client_hello_size], &hello.schema);
    return buffer[0..client_hello_size];
}

pub fn decodeClientHello(payload: []const u8) DecodeError!ClientHello {
    if (try decodeHeader(payload) != .client_hello) return error.UnexpectedMessage;
    if (payload.len != client_hello_size) return error.InvalidLength;
    return .{ .schema = payload[header_size..client_hello_size][0..schema_id.len].* };
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
    if (buffer.len < server_accept_size) return error.BufferTooSmall;
    writeHeader(buffer, .server_accept);
    @memcpy(buffer[header_size..server_accept_size], &accepted.schema);
    return buffer[0..server_accept_size];
}

fn decodeServerAccept(payload: []const u8) DecodeError!ServerAccept {
    if (payload.len != server_accept_size) return error.InvalidLength;
    return .{ .schema = payload[header_size..server_accept_size][0..schema_id.len].* };
}

fn encodeServerReject(buffer: []u8, rejected: ServerReject) EncodeError![]const u8 {
    if (buffer.len < server_reject_size) return error.BufferTooSmall;
    writeHeader(buffer, .server_reject);
    buffer[header_size] = @intFromEnum(rejected.reason);
    @memcpy(buffer[header_size + 1 .. server_reject_size], &rejected.expected_schema);
    return buffer[0..server_reject_size];
}

fn decodeServerReject(payload: []const u8) DecodeError!ServerReject {
    if (payload.len != server_reject_size) return error.InvalidLength;
    const reason: RejectReason = switch (payload[header_size]) {
        @intFromEnum(RejectReason.incompatible_schema) => .incompatible_schema,
        else => return error.UnknownRejectReason,
    };
    return .{
        .reason = reason,
        .expected_schema = payload[header_size + 1 .. server_reject_size][0..schema_id.len].*,
    };
}

fn writeHeader(buffer: []u8, tag: Tag) void {
    @memcpy(buffer[0..magic.len], &magic);
    buffer[magic.len] = @intFromEnum(tag);
}

fn decodeHeader(payload: []const u8) DecodeError!Tag {
    if (payload.len < header_size) return error.InvalidLength;
    if (!std.mem.eql(u8, payload[0..magic.len], &magic)) return error.InvalidMagic;
    return switch (payload[magic.len]) {
        @intFromEnum(Tag.client_hello) => .client_hello,
        @intFromEnum(Tag.server_accept) => .server_accept,
        @intFromEnum(Tag.server_reject) => .server_reject,
        else => error.UnknownMessage,
    };
}

test "client hello has a stable byte representation" {
    var buffer: [client_hello_size]u8 = undefined;
    const encoded = try encodeClientHello(&buffer, .{});

    try std.testing.expectEqualSlices(u8, &magic, encoded[0..magic.len]);
    try std.testing.expectEqual(@intFromEnum(Tag.client_hello), encoded[magic.len]);
    try std.testing.expectEqualSlices(u8, &schema_id, encoded[header_size..]);
    try std.testing.expectEqual(schema_id, (try decodeClientHello(encoded)).schema);
}

test "only the exact schema is accepted" {
    try std.testing.expectEqualDeep(
        ServerResponse{ .accepted = .{ .schema = schema_id } },
        negotiate(schema_id, schema_id),
    );

    var incompatible = schema_id;
    incompatible[0] ^= 1;
    const response = negotiate(incompatible, schema_id);
    try std.testing.expectEqual(RejectReason.incompatible_schema, response.rejected.reason);
    try std.testing.expectEqual(schema_id, response.rejected.expected_schema);
}

test "server responses round trip" {
    var incompatible = schema_id;
    incompatible[0] ^= 1;
    const responses = [_]ServerResponse{
        .{ .accepted = .{ .schema = schema_id } },
        .{ .rejected = .{ .reason = .incompatible_schema, .expected_schema = incompatible } },
    };
    for (responses) |response| {
        var buffer: [max_message_size]u8 = undefined;
        const encoded = try encodeServerResponse(&buffer, response);
        try std.testing.expectEqualDeep(response, try decodeServerResponse(encoded));
    }
}

test "malformed handshakes are rejected" {
    var buffer: [client_hello_size]u8 = undefined;
    const valid = try encodeClientHello(&buffer, .{});

    var wrong_magic = buffer;
    wrong_magic[0] = 'X';
    try std.testing.expectError(error.InvalidMagic, decodeClientHello(&wrong_magic));

    var wrong_tag = buffer;
    wrong_tag[magic.len] = 0xff;
    try std.testing.expectError(error.UnknownMessage, decodeClientHello(&wrong_tag));
    try std.testing.expectError(error.InvalidLength, decodeClientHello(valid[0 .. valid.len - 1]));
}
