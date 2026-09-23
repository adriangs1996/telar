//! One owned hover target. Pointer movement within a cell does no text scanning.
const hover_target = @import("hover_target.zig");
const data = @import("model");
const std = @import("std");
const core = @import("telar-core");
const GuiAdapter = @import("../GuiAdapter.zig");
const Event = @import("PointerEvent.zig");
const message_links = @import("../widgets/interaction/message_links.zig");
const Hit = @import("LinkHit.zig");
const Hover = @This();

event: ?Event = null,
cached: ?Stamp = null,
shape: core.PointerShape = .default,
link: ?Hit = null,
shown_link: ?Hit = null,
prepared_link: ?Hit = null,
shown_preview: ?core.Rect = null,
prepared_preview: ?core.Rect = null,
revision: u64 = 0,
dirty: bool = true,

/// Copies native coordinates for re-evaluation after output, resize or modifiers.
/// Example: `hover.observe(event);`
pub fn observe(self: *Hover, event: Event) void {
    if (event.kind == .leave) {
        self.clear();
        return;
    }

    self.event = event;
}

/// Reuses the cached cell until model state or delivered controls change.
/// Example: `hover.refresh(gui);`
pub fn refresh(self: *Hover, gui: *GuiAdapter) void {
    if (!gui.focused) {
        self.clear();
        return;
    }

    const event = self.event orelse return;
    if (gui.review.active) {
        self.assign(null, .default);
        self.cached = null;
        return;
    }

    if (gui.widgets.tab_drag.dragging and gui.widgets.tab_drag.source != null) {
        self.assign(null, .grabbing);
        self.cached = null;
        return;
    }

    if (gui.overlays.presented().native_modal != null) {
        const target = gui.widgets.dispatcher.maps.presented().at(.{ event.x, event.y });
        const shape: core.PointerShape = if (target) |control| if (control.action == .text_field) .text else if (control.enabled and control.activatable()) .pointer else .default else .default;
        self.assign(null, shape);
        self.cached = null;
        return;
    }

    if (!gui.app.model.name_prompt.active() and gui.overlays.presented().modal == null) {
        if (gui.overlays.presented().notifications.at(.{ event.x, event.y })) |target| {
            self.assign(null, if (target.enabled) .pointer else .default);
            self.cached = null;
            return;
        }
    }

    if (!gui.app.model.name_prompt.active() and gui.overlays.presented().modal == null and gui.widgets.composer_menu.selector == null and !gui.widgets.thread_selection.dragging) {
        if (gui.widgets.dispatcher.maps.presented().at(.{ event.x, event.y })) |target| {
            if (target.enabled and target.action == .message_link and gui.pointerGeometryMatches() and message_links.destination(gui, target.action.message_link) != null) {
                self.assign(null, .pointer);
                self.cached = null;
                return;
            }
        }
    }

    var moved = event;
    moved.kind = .move;
    const mouse = gui.pointer.geometry.resolve(moved) orelse {
        self.assign(null, gui.chrome.bandShape(moved));
        self.cached = null;
        return;
    };
    const cell: [2]u16 = .{ mouse.x, mouse.y };
    const stamp = Stamp.capture(gui, cell, event.mods);
    if (!self.dirty and std.meta.eql(self.cached, @as(?Stamp, stamp))) {
        return;
    }

    self.cached = stamp;
    self.dirty = false;
    const target = hover_target.resolve(gui, mouse, event.mods);
    self.assign(target.link, target.shape);
    if (target.link) |hit| {
        const pane = gui.app.model.panes.findInConst(gui.app.model.tabs.location[gui.app.model.tabs.active].tab_id, hit.pane_id).?;
        if (pane.pending_frame_id == 0) {
            self.shown_link = hit;
        }
    }
}

/// An in-flight update may be clicked only when the same target was visible.
/// Example: `if (hover.openable()) gesture.begin(hover.link.?);`
pub fn openable(self: *const Hover) bool {
    const current = self.link orelse return false;
    const shown = self.shown_link orelse return false;
    return current.eql(&shown);
}

/// Seals the overlay bounds with the frame, independently of later pointer motion.
/// Example: `hover.prepare();`
pub fn prepare(self: *Hover) void {
    self.prepared_link = self.link;
    self.prepared_preview = if (self.link) |*hit| hit.previewArea() else null;
}

/// Visible previews cover terminal cells until a replacement is delivered.
/// Example: `if (hover.covers(mouse)) return .{ .consumed = true };`
pub fn covers(self: *const Hover, mouse: data.Mouse) bool {
    const preview = self.shown_preview orelse return false;
    return preview.contains(mouse.x, mouse.y);
}

/// Presentation publishes only the target captured by that frame's preparation.
/// Example: `hover.present(delivered);`
pub fn present(self: *Hover, delivered: bool) void {
    if (delivered) {
        self.shown_link = self.prepared_link;
        self.shown_preview = self.prepared_preview;
    }

    self.prepared_link = null;
    self.prepared_preview = null;
    self.dirty = true;
}

fn assign(self: *Hover, next: ?Hit, shape: core.PointerShape) void {
    const same = if (self.link) |*previous| if (next) |*current| previous.eql(current) else false else next == null;
    if (!same) {
        self.link = next;
        self.revision +%= 1;
    }

    self.shape = shape;
}

/// Losing pointer focus removes the highlight and invalidates the cached cell.
/// Example: `hover.clear();`
pub fn clear(self: *Hover) void {
    self.event = null;
    self.cached = null;
    self.shown_link = null;
    self.dirty = true;
    self.assign(null, .default);
}

/// Every dependency of native hit testing, independent of GPU preparation.
const Stamp = struct {
    cell: [2]u16,
    mods: u32,
    model: data.Version,
    geometry: u64,
    chrome: u64,
    chrome_gesture: ?u8,
    sidebar_resize: bool,
    overlay_gesture: ?u8,

    /// Captures only values; no model or hit-map pointer escapes.
    /// Example: `const stamp = HoverStamp.capture(gui, cell, mods);`
    pub fn capture(gui: *const GuiAdapter, cell: [2]u16, mods: u32) Stamp {
        return .{ .cell = cell, .mods = mods, .model = gui.app.model.version(), .geometry = gui.pointer.revision, .chrome = gui.chrome.revision, .chrome_gesture = gui.chrome.gesture_button, .sidebar_resize = gui.chrome.sidebar_resize_active, .overlay_gesture = gui.overlays.gesture };
    }
};
