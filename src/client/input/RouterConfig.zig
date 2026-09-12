const KeyType = @import("Key.zig");
const model = @import("../config/model.zig");
/// Everything an adapter needs to compile its key router from configuration.
const RouterConfig = @This();

prefix: KeyType,
bindings: []const model.ConfiguredBinding,
escape_timeout_ns: u64,
sequence_timeout_ns: u64,
