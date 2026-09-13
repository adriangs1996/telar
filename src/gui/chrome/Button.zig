const core = @import("telar-core");
const client = @import("telar-client");

area: core.Rect,
intent: client.Intent,
text: []const u8,
active: bool = false,
