//! Native geometry and hit testing implement the shared chrome port.
const client = @import("telar-client");
const GuiClient = @import("../GuiClient.zig");
const Overlays = @import("../overlays/Overlays.zig");

/// Example: `app.chrome = chrome.port(app);`
pub fn port(app: *client.AttachedClient) client.HostChrome {
    return .{
        .context = app,
        .set_theme_fn = setTheme,
        .set_icon_theme_fn = setIcons,
        .configure_sidebar_fn = configureSidebar,
        .resize_fn = resize,
        .set_sidebar_layout_fn = sidebarLayout,
        .set_workspace_list_collapsed_fn = workspaceList,
        .pointer_fn = pointer,
        .link_pointer_fn = linkPointer,
        .sidebar_renderer_fn = sidebarRenderer,
        .adopt_sidebar_renderer_fn = adoptSidebarRenderer,
        .region_fn = region,
        .inspection_scroll_limit_fn = inspectionScrollLimit,
    };
}

fn host(context: *anyopaque) *GuiClient {
    const app: *client.AttachedClient = @ptrCast(@alignCast(context));
    return GuiClient.of(app);
}

fn setTheme(context: *anyopaque, theme: client.ColorTheme) void {
    host(context).theme = theme;
}

fn setIcons(_: *anyopaque, _: client.Theme) void {}

fn configureSidebar(_: *anyopaque, _: client.SidebarRendererInput) !void {}

fn resize(context: *anyopaque, cols: u16, rows: u16) !void {
    host(context).resizeRegion(cols, rows);
}

fn sidebarLayout(context: *anyopaque, _: bool, _: u16) void {
    const gui = host(context);
    const size = gui.app.model.hostSize();
    gui.resizeRegion(size.cols, size.rows);
}

fn workspaceList(_: *anyopaque, _: bool) void {}

fn pointer(context: *anyopaque, event: client.Mouse) client.ViewInteractionCommand {
    const gui = host(context);
    // A prompt can open before its first paint; it already owns the pointer.
    if (gui.app.model.name_prompt.active() and gui.overlays.presented().modal == null) {
        return .{ .consumed = true };
    }

    if (gui.overlays.pointer(event)) |interaction| {
        return interaction;
    }

    if (gui.input.pointer.hover.covers(event)) {
        if (event.kind == .press) {
            gui.overlays.gesture = event.button & 3;
        }

        return .{ .consumed = true };
    }

    return gui.chrome.pointer(event);
}

fn linkPointer(context: *anyopaque, event: client.Mouse) bool {
    if (event.kind != .press or event.button & 3 != 0) {
        return false;
    }

    const gui = host(context);
    const routing = &gui.input.pointer;
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

fn sidebarRenderer(_: *anyopaque) client.SidebarRendering {
    return .cells;
}

fn adoptSidebarRenderer(_: *anyopaque, _: client.SidebarRendering) void {}

fn region(context: *anyopaque) client.Region {
    return host(context).region;
}

fn inspectionScrollLimit(context: *anyopaque) ?u32 {
    return Overlays.inspectionScrollLimit(host(context).projection());
}
