const clipboard_image = @import("clipboard_image.zig");
const CompletionDelivery = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, clipboard_image.CompletionOutcome) anyerror!void,
