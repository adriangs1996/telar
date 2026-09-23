const std = @import("std");
const AttachmentStore = @import("../attachment/AttachmentStore.zig");
const Sources = @import("Sources.zig");
const RuntimeMetrics = @import("../observability/RuntimeMetrics.zig");
const Preparation = @This();

io: std.Io,
attachments: *AttachmentStore,
sources: Sources,
metrics: *RuntimeMetrics,
