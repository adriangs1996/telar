const Prepared = @import("Prepared.zig");
const AttachmentStore = @import("../attachment/AttachmentStore.zig");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const Commit = @This();

prepared: Prepared,
attachments: *AttachmentStore,
metrics: *RuntimeMetrics,
