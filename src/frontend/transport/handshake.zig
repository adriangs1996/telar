//! Client half of protocol version negotiation.

const core = @import("telar-core");
const schema = core.schema.handshake;

pub fn perform(io: @import("std").Io, connection: anytype) !schema.ServerResponse {
    return performVersions(io, connection, schema.supported_versions);
}

pub fn performVersions(
    io: @import("std").Io,
    connection: anytype,
    requested: schema.VersionRange,
) !schema.ServerResponse {
    var request_buffer: [schema.max_message_size]u8 = undefined;
    const request = try schema.encodeClientHello(&request_buffer, .{ .versions = requested });
    try connection.send(io, request);

    var response_buffer: [schema.max_message_size]u8 = undefined;
    const response_payload = try connection.receive(io, &response_buffer);
    const response = try schema.decodeServerResponse(response_payload);
    switch (response) {
        .accepted => |accepted| {
            if (!requested.contains(accepted.version)) return error.InvalidServerSelection;
        },
        .rejected => {},
    }
    return response;
}
