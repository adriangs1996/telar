const core = @import("telar-core");
const data = @import("model");
const WorkerResult = @This();

package_index: u8,
plugin_id: u64,
digest: core.Digest,
batch: data.EffectBatch,
