const StartEffects = @This();
const client_model = @import("../../root.zig").model;
context: *anyopaque,
schedule: *const fn (*anyopaque, client_model.ClipboardCapture) anyerror!void,
