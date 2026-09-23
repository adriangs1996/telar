//! Native hit testing answers the shared chrome port.
const data = @import("model");
const client = @import("telar-client");
const hover_target = @import("../input/hover_target.zig");
const GuiClient = @import("../GuiClient.zig");

/// Example: `gui.app.chrome = chrome.port(gui);`
pub fn port(gui: *GuiClient) client.HostChrome {
    return .{
        .context = gui,
        .pointer_fn = pointer,
        .link_pointer_fn = linkPointer,
        .inspection_scroll_limit_fn = inspectionScrollLimit,
    };
}

fn host(context: *anyopaque) *GuiClient {
    return @ptrCast(@alignCast(context));
}

fn pointer(context: *anyopaque, event: data.Mouse) client.ViewInteractionCommand {
    const gui = host(context);
    // A prompt can open before its first paint; it already owns the pointer.
    if (gui.app.model.name_prompt.active() and gui.overlays.presented().modal == null) {
        return .{ .consumed = true };
    }

    if (gui.overlays.pointer(event)) |interaction| {
        return interaction;
    }

    if (gui.pointer.hover.covers(event)) {
        if (event.kind == .press) {
            gui.overlays.gesture = event.button & 3;
        }

        return .{ .consumed = true };
    }

    return gui.chrome.pointer(event);
}

fn linkPointer(context: *anyopaque, event: data.Mouse) bool {
    if (event.kind != .press or event.button & 3 == 1) {
        return false;
    }

    const gui = host(context);
    const routing = &gui.pointer;
    if (event.button & 3 == 2) {
        const hit = hover_target.resolve(gui, event, hover_target.link_modifier | 1).link orelse return false;
        const pane = gui.app.model.panes.findInConst(gui.app.model.tabs.location[gui.app.model.tabs.active].tab_id, hit.pane_id).?;
        if (pane.pending_frame_id == 0) {
            gui.copyLink(hit.match.target.uri()) catch {};
        }

        return true;
    }

    routing.hover.dirty = true;
    routing.hover.refresh(gui);
    const hit = routing.hover.link orelse return false;
    if (routing.hover.openable()) {
        routing.link_gesture.begin(hit, gui.app.model.version());
    } else {
        routing.link_gesture.cancel();
    }

    return true;
}

fn inspectionScrollLimit(context: *anyopaque) ?u32 {
    const gui = host(context);
    return gui.overlays.inspectionScrollLimit(gui.projection());
}
