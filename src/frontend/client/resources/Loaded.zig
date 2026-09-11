const Loaded = @This();
const lua_config = @import("../../config/root.zig");
const plugin_broker = @import("../../plugins/root.zig");
const core = @import("telar-core");
generation: *lua_config.Generation,
registry: *plugin_broker.Registry,
trust_store: *core.plugin.TrustStore,
mtime_ns: i128,
