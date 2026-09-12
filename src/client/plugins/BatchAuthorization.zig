const DigestType = @import("telar-core").Digest;
const EffectBatchType = @import("../config/EffectBatch.zig");
const BatchAuthorization = @This();

package_index: u8,
plugin_id: u64,
digest: DigestType,
batch: *const EffectBatchType,
