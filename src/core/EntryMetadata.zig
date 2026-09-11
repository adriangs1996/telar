const schema_contract_test = @import("schema_contract_test.zig");
const EntryMetadata = @This();

name: []const u8,
direction: schema_contract_test.Direction,
golden_hex: []const u8,
