//! Client half of the exact-schema handshake.

const core = @import("telar-core");
const schema = core.handshake;

pub fn perform(io: @import("std").Io, connection: anytype) !schema.ServerResponse {
    return performSchema(io, connection, schema.schema_id);
}

pub fn performSchema(io: @import("std").Io, connection: anytype, requested: schema.SchemaId) !schema.ServerResponse {
    var request_buffer: [schema.max_message_size]u8 = undefined;
    const request = try schema.encodeClientHello(&request_buffer, .{ .schema = requested });
    try connection.send(io, request);

    var response_buffer: [schema.max_message_size]u8 = undefined;
    const response_payload = try connection.receive(io, &response_buffer);
    const response = try schema.decodeServerResponse(response_payload);
    switch (response) {
        .accepted => |accepted| {
            if (!@import("std").mem.eql(u8, &requested, &accepted.schema)) {
                return error.InvalidServerSelection;
            }
        },
        .rejected => {},
    }
    return response;
}
