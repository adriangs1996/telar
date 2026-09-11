const Commit = @This();
const Prepared = @import("Prepared.zig");
const source_namespace = @import("root.zig");
prepared: Prepared,
attachments: *source_namespace.AttachmentStore,
metrics: *source_namespace.RuntimeMetrics,
