//! Server half of the exact-schema handshake.

const std = @import("std");
const ServerResponseType = @import("telar-core").ServerResponse;
const schema_id_module = @import("telar-core").schema_id;
const SchemaIdType = @import("telar-core").SchemaId;
const max_message_size_module = @import("telar-core").max_message_size;
const decodeClientHello_module = @import("telar-core").decodeClientHello;
const negotiate_module = @import("telar-core").negotiate;
const encodeServerResponse_module = @import("telar-core").encodeServerResponse;

pub fn perform(io: std.Io, connection: anytype) !ServerResponseType {
    return performSchema(io, connection, schema_id_module);
}

/// Negotiates an explicit schema identifier, primarily for compatibility tests.
///
/// ```zig
/// const response = try performSchema(io, &connection, supported);
/// ```
pub fn performSchema(io: std.Io, connection: anytype, supported: SchemaIdType) !ServerResponseType {
    var request_buffer: [max_message_size_module]u8 = undefined;
    const request = try connection.receive(io, &request_buffer);
    const hello = try decodeClientHello_module(request);
    const response = negotiate_module(hello.schema, supported);

    var response_buffer: [max_message_size_module]u8 = undefined;
    const encoded = try encodeServerResponse_module(&response_buffer, response);
    try connection.send(io, encoded);
    return response;
}
