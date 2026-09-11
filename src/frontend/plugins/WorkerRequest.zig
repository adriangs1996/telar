const DigestType = @import("telar-core").Digest;
const Package = @import("Package.zig");
const max_action_bytes_module = @import("telar-core").max_action_bytes;
const CallbackContextType = @import("telar-client").CallbackContext;
const WorkerRequest = @This();

package_index: u8,
plugin_id: u64,
digest: DigestType,
package: Package,
action_bytes: [max_action_bytes_module]u8 = undefined,
action_len: u8,
context: CallbackContextType,

pub fn action(request: *const WorkerRequest) []const u8 {
    return request.action_bytes[0..request.action_len];
}
