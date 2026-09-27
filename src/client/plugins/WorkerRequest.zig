const core = @import("telar-core");
const data = @import("model");
const Package = @import("Package.zig");
const WorkerRequest = @This();

package_index: u8,
plugin_id: u64,
digest: core.Digest,
package: Package,
action_bytes: [core.max_action_bytes]u8 = undefined,
action_len: u8,
context: data.CallbackContext,
/// The telar binary that runs the worker; null is this executable.
executable: ?[]const u8 = null,

pub fn action(self: *const WorkerRequest) []const u8 {
    return self.action_bytes[0..self.action_len];
}
