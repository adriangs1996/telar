const HeadTransform = @This();
const MessageRoute = @import("MessageRoute.zig");
const middleware = @import("../middleware.zig");
const std = @import("std");
const HeadSink = @import("HeadSink.zig");
route: MessageRoute,
pipeline: *const middleware.TransformPipeline,
io: std.Io,
context: middleware.TransformContext,
capture: ?HeadSink = null,
