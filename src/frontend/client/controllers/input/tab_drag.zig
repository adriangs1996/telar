//! Terminal gesture capture around the shared semantic tab move.
const std = @import("std");
const client = @import("telar-client");
const host = @import("../../TerminalClient.zig").of;

/// Called by chrome after existing pane-selection and modal owners.
/// Example: `const command = tab_drag.press(app, mouse) orelse view.handleMouse(mouse);`
pub fn press(app: *client.AttachedClient, mouse: client.Mouse) ?client.ViewInteractionCommand {
    if (mouse.kind != .press) {
        return null;
    }

    const view = &host(app).view;
    const tabs = &view.tab_drag;
    const tab_id = tabs.hits.at(mouse.x, mouse.y) orelse return null;
    const delivered = app.presentation.deliveredGeometry() orelse return .{ .consumed = true };
    const current = client.Geometry.capture(client.capture(&app.model, .{ .geometry = app.geometry() }));
    if (!delivered.matches(&current)) {
        return .{ .consumed = true };
    }

    if (view.attachment_store.hasModal() or !std.meta.eql(tabs.workspace, app.model.workspace.workspace)) {
        return .{ .consumed = true };
    }

    const workspace = tabs.workspace orelse return .{ .consumed = true };
    if (app.model.workspace.indexOf(tab_id) == null) {
        return .{ .consumed = true };
    }

    switch (mouse.button & 3) {
        0 => {
            tabs.gesture.begin(.{ .workspace = workspace, .tab_id = tab_id }, .{ @floatFromInt(mouse.x), @floatFromInt(mouse.y) });
            return .{ .consumed = true, .intent = .{ .select_tab = tab_id } };
        },
        2 => return .{ .consumed = true, .intent = .{ .rename_tab = tab_id } },
        else => return .{ .consumed = true },
    }
}

/// Retained events bypass other owners, including prompts opened mid-drag.
/// Example: `if (try tab_drag.retained(app, mouse)) return;`
pub fn retained(app: *client.AttachedClient, event: client.Mouse) !bool {
    const view = &host(app).view;
    const tabs = &view.tab_drag;
    if (!tabs.gesture.captured or (event.kind != .drag and event.kind != .release) or (event.button & 3 != 0 and !(event.kind == .release and event.button & 3 == 3))) {
        return false;
    }

    var mouse = event;
    const size = app.model.hostSize();
    if (app.model.hostCapabilities().pointer_pixels == .supported and size.cell_width_px != 0 and size.cell_height_px != 0) {
        mouse.x = std.math.cast(u16, event.raw_x / size.cell_width_px) orelse std.math.maxInt(u16);
        mouse.y = std.math.cast(u16, event.raw_y / size.cell_height_px) orelse std.math.maxInt(u16);
    }

    tabs.gesture.validate(&app.model);
    if (view.attachment_store.hasModal()) {
        tabs.gesture.cancel();
    }

    tabs.gesture.update(.{ @floatFromInt(mouse.x), @floatFromInt(mouse.y) }, tabs.destination(mouse));
    view.dirty = true;
    view.interaction_revision +%= 1;
    if (mouse.kind == .release) {
        if (tabs.gesture.finish()) |move| {
            const model = app.model.activeTabModel() orelse return true;
            _ = try client.controllers.view_interactions.apply(app, model, .{ .intent = .{ .move_tab = move }, .consumed = true });
        }
    }

    return true;
}

/// Example: `if (tab_drag.cancel(app)) return;`
pub fn cancel(app: *client.AttachedClient) bool {
    const view = &host(app).view;
    if (!view.tab_drag.gesture.captured) {
        return false;
    }

    view.tab_drag.gesture.cancel();
    view.dirty = true;
    view.interaction_revision +%= 1;
    return true;
}
