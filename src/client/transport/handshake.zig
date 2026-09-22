//! Client half of the exact-schema handshake.

const core = @import("telar-core");
const std = @import("std");

pub fn perform(io: std.Io, connection: anytype) !core.ServerResponse {
    return performSchema(io, connection, core.schema_id);
}

pub fn performSchema(io: std.Io, connection: anytype, requested: core.SchemaId) !core.ServerResponse {
    var request_buffer: [core.max_message_size]u8 = undefined;
    const request = try core.encodeClientHello(&request_buffer, .{ .schema = requested });
    try connection.send(io, request);

    var response_buffer: [core.max_message_size]u8 = undefined;
    const response_payload = try connection.receive(io, &response_buffer);
    const response = try core.decodeServerResponse(response_payload);
    switch (response) {
        .accepted => |accepted| {
            if (!std.mem.eql(u8, &requested, &accepted.schema)) {
                return error.InvalidServerSelection;
            }
        },
        .rejected => {},
    }
    return response;
}
