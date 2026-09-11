const schema_contract_test = @import("schema_contract_test.zig");
const Entry = @This();

name: []const u8,
direction: schema_contract_test.Direction,
/// The payload tail is raw bytes without a length prefix, so a prefix of
/// the message can decode as a valid shorter message.
tail_tolerant: bool = false,
bytes: []const u8,
golden_hex: []const u8,
