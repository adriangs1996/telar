const data = @import("model");
/// Everything an adapter needs to compile its key router from configuration.
const RouterConfig = @This();

prefix: data.Key,
bindings: []const data.config_values.ConfiguredBinding,
escape_timeout_ns: u64,
sequence_timeout_ns: u64,
