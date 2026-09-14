//! Resolves native affordances through the delivered controls before pane text.
const builtin = @import("builtin");
const core = @import("telar-core");
const client = @import("telar-client");
const GuiClient = @import("../GuiClient.zig");
const Target = @import("HoverTarget.zig");

pub const link_modifier: u32 = if (builtin.os.tag == .macos) 8 else 4;

/// Native link modifiers are never encoded into child mouse coordinates.
/// Example: `const target = resolve(gui, mouse, event.mods);`
pub fn resolve(gui: *const GuiClient, mouse: client.Mouse, mods: u32) Target {
    if (!gui.focused) {
        return .{};
    }

    const overlays = gui.overlays.presented();
    if (gui.app.model.name_prompt.active() or overlays.modal != null) {
        if (overlays.palette.at(mouse) != null) {
            return .{ .shape = .pointer };
        }

        return .{ .shape = if (overlays.modal) |area| if (area.inner(1).contains(mouse.x, mouse.y)) .text else .default else .default };
    }

    if (gui.overlays.gesture != null) {
        return .{};
    }

    if (overlays.notifications.at(mouse) != null) {
        return .{ .shape = .pointer };
    }

    if (gui.input.pointer.hover.covers(mouse)) {
        return .{};
    }

    if (gui.chrome.sidebar_resize_active) {
        return .{ .shape = .col_resize };
    }

    const action = gui.chrome.presented().hits.at(.{ mouse.x, mouse.y }) orelse return .{};
    switch (action) {
        .resize_sidebar => return .{ .shape = .col_resize },
        .intent => |intent| return .{ .shape = if (intent == .none) .default else .pointer },
        .pane_content => |id| {
            const model = gui.app.model.activeTabModelConst() orelse return .{};
            const pane = model.findConst(id) orelse return .{};
            var layout: client.LayoutSnapshot = .{};
            model.layout.snapshot(gui.region.area, &layout);
            const view = layout.find(id) orelse return .{};
            if (view.surface != .terminal or !view.content.contains(mouse.x, mouse.y)) {
                return .{};
            }

            const base: Target = .{ .shape = if (pane.pointer_shape == .default) .text else pane.pointer_shape };
            if (gui.app.model.copyModeActive() or gui.chrome.gesture_button != null or !pane.attached) {
                return base;
            }

            const reporting = pane.mouse.tracking != .none;
            if (mods & link_modifier == 0 or mods & 2 != 0 or (reporting and mods & 1 == 0)) {
                return base;
            }

            const row = pane.scroll.offset + (mouse.y - view.content.y);
            const found = client.resolveLink(pane, .{ .x = mouse.x - view.content.x, .y = row }) orelse return base;
            const start_x = if (row == found.start.y) found.start.x else 0;
            const end_x = @min(if (row == found.end.y) found.end.x else pane.buffer.w, view.content.w);
            if (start_x >= end_x) {
                return base;
            }

            return .{ .shape = .pointer, .link = .{
                .pane_id = pane.id,
                .generation = pane.attachment_generation,
                .location = model.location orelse return base,
                .content = view.content,
                .scroll_offset = pane.scroll.offset,
                .area = .{ .x = view.content.x + start_x, .y = mouse.y, .w = end_x - start_x, .h = 1 },
                .match = found,
            } };
        },
    }
}
