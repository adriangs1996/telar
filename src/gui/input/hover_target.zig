//! Resolves native affordances through the delivered controls before pane text.
const keyinput = @import("keyinput");
const data = @import("model");
const client = @import("telar-client");
const builtin = @import("builtin");
const WindowModel = @import("../WindowModel.zig");
const Target = @import("HoverTarget.zig");

pub const link_modifier: u32 = if (builtin.os.tag == .macos) 8 else 4;

/// Native link modifiers are never encoded into child mouse coordinates.
/// Example: `const target = resolve(&gui.model, gui.app, mouse, event.mods);`
pub fn resolve(model: *WindowModel, app: *client.Client, mouse: keyinput.Mouse, mods: u32) Target {
    if (!model.focused) {
        return .{};
    }

    const overlays = model.overlays.presented();
    if (app.model.name_prompt.active() or overlays.modal != null) {
        if (overlays.palette.at(mouse) != null) {
            return .{ .shape = .pointer };
        }

        return .{ .shape = if (overlays.modal) |area| if (area.inner(1).contains(mouse.x, mouse.y)) .text else .default else .default };
    }

    if (model.overlays.gesture != null) {
        return .{};
    }

    if (model.pointer.hover.covers(mouse)) {
        return .{};
    }

    if (model.chrome.sidebar_resize_active) {
        return .{ .shape = .col_resize };
    }

    const action = model.chrome.presented().hits.at(.{ mouse.x, mouse.y }) orelse return .{};
    switch (action) {
        .resize_sidebar => return .{ .shape = .col_resize },
        .intent => |intent| return .{ .shape = if (intent == .none) .default else .pointer },
        .pane_content => |id| {
            const tab = app.model.tabs.activeSlot() orelse return .{};
            const pane = app.model.panes.findInConst(app.model.tabs.location[tab].tab_id, id) orelse return .{};
            const view = data.tab_layout.view(&app.model, tab, id, data.workbench.region(&app.model).area) orelse return .{};
            if (!view.content.contains(mouse.x, mouse.y)) {
                return .{};
            }

            const base: Target = .{ .shape = if (pane.pointer_shape == .default) .text else pane.pointer_shape };
            if (data.copy_mode.isActive(&app.model) or model.chrome.gesture_button != null or !pane.attached) {
                return base;
            }

            const row = pane.scroll.offset + (mouse.y - view.content.y);
            const found = data.cells.resolve(pane, .{ .x = mouse.x - view.content.x, .y = row }) orelse return base;
            const start_x = if (row == found.start.y) found.start.x else 0;
            const end_x = @min(if (row == found.end.y) found.end.x else pane.buffer.w, view.content.w);
            if (start_x >= end_x) {
                return base;
            }

            // Alt keeps the text plain for selection. Every other hover shows
            // the link; the press policy in `ports/chrome.zig` decides who opens it.
            if (mods & 2 != 0) {
                return .{ .shape = .pointer };
            }

            // A path in prose is a guess, so it is a link only while the
            // platform modifier asks for one; plain clicks stay with the text.
            if (found.target.scheme == .path and mods & link_modifier == 0) {
                return base;
            }

            return .{ .shape = .pointer, .link = .{
                .pane_id = pane.id,
                .generation = pane.attachment_generation,
                .location = app.model.tabs.location[tab],
                .content = view.content,
                .scroll_offset = pane.scroll.offset,
                .area = .{ .x = view.content.x + start_x, .y = mouse.y, .w = end_x - start_x, .h = 1 },
                .match = found,
            } };
        },
    }
}
