const FrameAckType = @import("telar-core").FrameAck;
const Effects = @This();

context: *anyopaque,
flush_graphics_credits: *const fn (*anyopaque) anyerror!void,
acknowledge_frame: *const fn (*anyopaque, FrameAckType) anyerror!void,
request_media: *const fn (*anyopaque) anyerror!void,
