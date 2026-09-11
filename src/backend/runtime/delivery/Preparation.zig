const Preparation = @This();
const source_namespace = @import("root.zig");
const Sources = @import("Sources.zig");
io: source_namespace.Io,
attachments: *source_namespace.AttachmentStore,
sources: Sources,
metrics: *source_namespace.RuntimeMetrics,
