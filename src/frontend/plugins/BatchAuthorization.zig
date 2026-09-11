const BatchAuthorization = @This();
const source_namespace = @import("root.zig");
const lua_config = @import("../config/root.zig");
package_index: u8,
plugin_id: u64,
digest: source_namespace.plugin.Digest,
batch: *const lua_config.EffectBatch,
