const client = @import("telar-client");
const native = @import("native/native.zig");
wait: client.ConfigWaitArgs,
current: client.GuiConfig,
viewport: native.Viewport,
