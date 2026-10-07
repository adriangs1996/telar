//! The inspector scroll bound only the window's drawn chrome can answer.
//! Pointer hit testing runs in `window_input` between the client's routing
//! steps, so this port answers and never changes window state.

const GuiAdapter = @import("../GuiAdapter.zig");

pub fn inspectionScrollLimit(context: *anyopaque) ?u32 {
    const gui: *GuiAdapter = @ptrCast(@alignCast(context));
    return gui.model.overlays.inspectionScrollLimit(gui.projection());
}
