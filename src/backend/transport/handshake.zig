//! Server half of the exact-schema handshake.

const core = @import("telar-core");
const schema = core.handshake;

pub fn perform(io: @import("std").Io, connection: anytype) !schema.ServerResponse {
    return performSchema(io, connection, schema.schema_id);
}

pub fn performSchema(
    io: @import("std").Io,
    connection: anytype,
    supported: schema.SchemaId,
) !schema.ServerResponse {
    var request_buffer: [schema.max_message_size]u8 = undefined;
    const request = try connection.receive(io, &request_buffer);
    const hello = try schema.decodeClientHello(request);
    const response = schema.negotiate(hello.schema, supported);

    var response_buffer: [schema.max_message_size]u8 = undefined;
    const encoded = try schema.encodeServerResponse(&response_buffer, response);
    try connection.send(io, encoded);
    return response;
}
