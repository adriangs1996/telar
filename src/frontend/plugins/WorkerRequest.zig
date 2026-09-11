const WorkerRequest = @This();
const source_namespace = @import("root.zig");
const Package = @import("Package.zig");
const lua_config = @import("../config/root.zig");
package_index: u8,
plugin_id: u64,
digest: source_namespace.plugin.Digest,
package: Package,
action_bytes: [source_namespace.plugin.max_action_bytes]u8 = undefined,
action_len: u8,
context: lua_config.CallbackContext,

pub fn action(request: *const WorkerRequest) []const u8 {
    return request.action_bytes[0..request.action_len];
}
