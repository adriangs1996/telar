const types = @import("../../model/types.zig");
const DigestType = @import("telar-core").Digest;
const EffectBatchType = @import("../../config/EffectBatch.zig");
const PluginResult = @This();

execution_id: types.PluginExecutionId,
package_index: u8,
plugin_id: u64,
digest: DigestType,
/// Borrowed only while the completion handler executes synchronously.
batch: *const EffectBatchType,
