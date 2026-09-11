const MessageRoute = @import("MessageRoute.zig");
const TransformPipelineType = @import("../TransformPipeline.zig");
const std = @import("std");
const TransformContextType = @import("../TransformContext.zig");
const HeadSink = @import("HeadSink.zig");
const HeadTransform = @This();

route: MessageRoute,
pipeline: *const TransformPipelineType,
io: std.Io,
context: TransformContextType,
capture: ?HeadSink = null,
