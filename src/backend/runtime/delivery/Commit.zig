const Prepared = @import("Prepared.zig");
const AttachmentStoreType = @import("../attachment/AttachmentStore.zig");
const RuntimeMetricsType = @import("../observability/RuntimeMetrics.zig");
const Commit = @This();

prepared: Prepared,
attachments: *AttachmentStoreType,
metrics: *RuntimeMetricsType,
