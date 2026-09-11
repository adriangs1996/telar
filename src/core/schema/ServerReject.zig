const ServerReject = @This();
const source_namespace = @import("handshake.zig");
reason: source_namespace.RejectReason,
expected_schema: source_namespace.SchemaId,
