const MessageRoute = @import("MessageRoute.zig");
const TransformPipeline = @import("../TransformPipeline.zig");
const std = @import("std");
const TransformContext = @import("../TransformContext.zig");
const Half = @import("../capture/Half.zig");
const HeadTransform = @This();

route: MessageRoute,
pipeline: *const TransformPipeline,
io: std.Io,
context: TransformContext,
capture: ?*Half = null,
