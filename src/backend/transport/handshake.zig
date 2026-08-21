//! Server half of protocol version negotiation.

const core = @import("telar-core");
const schema = core.schema.handshake;

pub fn perform(io: @import("std").Io, connection: anytype) !schema.ServerResponse {
    return performVersions(io, connection, schema.supported_versions);
}

pub fn performVersions(
    io: @import("std").Io,
    connection: anytype,
    supported: schema.VersionRange,
) !schema.ServerResponse {
    var request_buffer: [schema.max_message_size]u8 = undefined;
    const request = try connection.receive(io, &request_buffer);
    const hello = try schema.decodeClientHello(request);
    const response = try schema.negotiate(hello.versions, supported);

    var response_buffer: [schema.max_message_size]u8 = undefined;
    const encoded = try schema.encodeServerResponse(&response_buffer, response);
    try connection.send(io, encoded);
    return response;
}
