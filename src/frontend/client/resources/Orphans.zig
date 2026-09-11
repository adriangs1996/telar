const Orphans = @This();
const lua_config = @import("../../config/root.zig");
const plugin_broker = @import("../../plugins/root.zig");
const core = @import("telar-core");
generation: ?*lua_config.Generation = null,
registry: ?*plugin_broker.Registry = null,
trust: ?*core.plugin.TrustStore = null,
