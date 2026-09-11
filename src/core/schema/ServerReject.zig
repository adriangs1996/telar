const handshake = @import("handshake.zig");
const ServerReject = @This();

reason: handshake.RejectReason,
expected_schema: handshake.SchemaId,
