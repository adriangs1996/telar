const PiFrame = @This();
const attachments = @import("../../attachments/root.zig");
target: attachments.Target,
prompt: []const u8,
id: u64,
