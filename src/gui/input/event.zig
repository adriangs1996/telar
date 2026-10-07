const core = @import("telar-core");
const Window = @import("telar-window");
const std = @import("std");

pub const clipboard_limit = core.Limit.declare("gui.clipboard.max_text_bytes", "clipboard bytes", Window.Input.max_text_bytes);
comptime {
    std.debug.assert(Window.Input.max_text_bytes >= core.max_clipboard_bytes);
}
