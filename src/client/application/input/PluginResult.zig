const PluginResult = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("plugin_action.zig");
const config = @import("../../config/root.zig");
execution_id: client_model.PluginExecutionId,
package_index: u8,
plugin_id: u64,
digest: source_namespace.plugin.Digest,
/// Borrowed only while the completion handler executes synchronously.
batch: *const config.EffectBatch,
