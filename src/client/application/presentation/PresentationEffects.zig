const Effects = @This();

context: *anyopaque,
flush_graphics_credits: *const fn (*anyopaque) anyerror!void,
request_media: *const fn (*anyopaque) anyerror!void,
