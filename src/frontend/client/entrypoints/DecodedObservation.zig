const ServerMessageType = @import("telar-core").ServerMessage;
const DecodedObservation = @This();

payload_len: usize,
message: ServerMessageType,
decode_started_ns: u64,
