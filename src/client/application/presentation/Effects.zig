const Effects = @This();
const source_namespace = @import("presentation_delivery.zig");
context: *anyopaque,
flush_graphics_credits: *const fn (*anyopaque) anyerror!void,
acknowledge_frame: *const fn (*anyopaque, source_namespace.schema.FrameAck) anyerror!void,
request_media: *const fn (*anyopaque) anyerror!void,
