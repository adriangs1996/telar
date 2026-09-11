const CompletionDelivery = @This();
const source_namespace = @import("clipboard_image.zig");
context: *anyopaque,
deliver: *const fn (*anyopaque, source_namespace.CompletionOutcome) anyerror!void,
