//! Client half of the exact-schema handshake.

const std = @import("std");
const ServerResponseType = @import("telar-core").ServerResponse;
const schema_id_module = @import("telar-core").schema_id;
const SchemaIdType = @import("telar-core").SchemaId;
const max_message_size_module = @import("telar-core").max_message_size;
const encodeClientHello_module = @import("telar-core").encodeClientHello;
const decodeServerResponse_module = @import("telar-core").decodeServerResponse;

pub fn perform(io: std.Io, connection: anytype) !ServerResponseType {
    return performSchema(io, connection, schema_id_module);
}

pub fn performSchema(io: std.Io, connection: anytype, requested: SchemaIdType) !ServerResponseType {
    var request_buffer: [max_message_size_module]u8 = undefined;
    const request = try encodeClientHello_module(&request_buffer, .{ .schema = requested });
    try connection.send(io, request);

    var response_buffer: [max_message_size_module]u8 = undefined;
    const response_payload = try connection.receive(io, &response_buffer);
    const response = try decodeServerResponse_module(response_payload);
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
