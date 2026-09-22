const data = @import("model");
const model = @import("../config/model.zig");
/// Everything an adapter needs to compile its key router from configuration.
const RouterConfig = @This();

prefix: data.Key,
bindings: []const model.ConfiguredBinding,
escape_timeout_ns: u64,
sequence_timeout_ns: u64,
