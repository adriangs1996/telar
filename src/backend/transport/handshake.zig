//! Server half of the exact-schema handshake.

const core = @import("telar-core");
const std = @import("std");

pub fn perform(io: std.Io, connection: anytype) !core.ServerResponse {
    return performSchema(io, connection, core.schema_id);
}

/// Negotiates an explicit schema identifier, primarily for compatibility tests.
///
/// ```zig
/// const response = try performSchema(io, &connection, supported);
/// ```
pub fn performSchema(io: std.Io, connection: anytype, supported: core.SchemaId) !core.ServerResponse {
    var request_buffer: [core.max_message_size]u8 = undefined;
    const request = try connection.receive(io, &request_buffer);
    const hello = try core.decodeClientHello(request);
    const response = core.negotiate(hello.schema, supported);

    var response_buffer: [core.max_message_size]u8 = undefined;
    const encoded = try core.encodeServerResponse(&response_buffer, response);
    try connection.send(io, encoded);
    return response;
}
