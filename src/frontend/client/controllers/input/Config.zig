const Config = @This();
const source_namespace = @import("host_inputs.zig");
const lua_config = @import("../../../config/root.zig");
prefix: source_namespace.keybind.Key,
bindings: []const lua_config.ConfiguredBinding,
escape_timeout_ns: u64,
sequence_timeout_ns: u64,
