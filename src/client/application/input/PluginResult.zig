const core = @import("telar-core");
const model_data = @import("model");
const PluginResult = @This();

execution_id: model_data.PluginExecutionId,
package_index: u8,
plugin_id: u64,
digest: core.Digest,
/// Borrowed only while the completion handler executes synchronously.
batch: *const model_data.EffectBatch,
