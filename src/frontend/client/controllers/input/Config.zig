const KeyType = @import("telar-client").Key;
const model = @import("../../../config/model.zig");
const Config = @This();

prefix: KeyType,
bindings: []const model.ConfiguredBinding,
escape_timeout_ns: u64,
sequence_timeout_ns: u64,
