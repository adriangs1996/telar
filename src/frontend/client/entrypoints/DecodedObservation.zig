const DecodedObservation = @This();
const source_namespace = @import("runtime_io.zig");
payload_len: usize,
message: source_namespace.schema.ServerMessage,
decode_started_ns: u64,
