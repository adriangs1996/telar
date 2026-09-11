const std = @import("std");
const AttachmentStoreType = @import("../attachment/AttachmentStore.zig");
const Sources = @import("Sources.zig");
const RuntimeMetricsType = @import("../observability/RuntimeMetrics.zig");
const Preparation = @This();

io: std.Io,
attachments: *AttachmentStoreType,
sources: Sources,
metrics: *RuntimeMetricsType,
