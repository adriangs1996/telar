//! One owned hover target. Pointer movement within a cell does no text scanning.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const GuiClient = @import("../GuiClient.zig");
const Event = @import("PointerEvent.zig");
const Hit = @import("LinkHit.zig");
const Stamp = @import("HoverStamp.zig");
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
pub fn observe(hover: *Hover, event: Event) void {
    if (event.kind == .leave) {
        hover.clear();
        return;
    }

    hover.event = event;
}

/// Reuses the cached cell until model state or delivered controls change.
/// Example: `hover.refresh(gui);`
pub fn refresh(hover: *Hover, gui: *const GuiClient) void {
    if (!gui.focused) {
        hover.clear();
        return;
    }

    const event = hover.event orelse return;
    if (!gui.app.model.name_prompt.active() and gui.overlays.presented().modal == null) {
        if (gui.overlays.presented().notifications.at(.{ event.x, event.y })) |target| {
            hover.assign(null, if (target.enabled) .pointer else .default);
            hover.cached = null;
            return;
        }
    }

    var moved = event;
    moved.kind = .move;
    const mouse = gui.input.pointer.geometry.resolve(moved) orelse {
        hover.assign(null, gui.chrome.bandShape(moved));
        hover.cached = null;
        return;
    };
    const cell: [2]u16 = .{ mouse.x, mouse.y };
    const stamp = Stamp.capture(gui, cell, event.mods);
    if (!hover.dirty and std.meta.eql(hover.cached, @as(?Stamp, stamp))) {
        return;
    }

    hover.cached = stamp;
    hover.dirty = false;
    const target = @import("hover_target.zig").resolve(gui, mouse, event.mods);
    hover.assign(target.link, target.shape);
    if (target.link) |hit| {
        const pane = gui.app.model.activeTabModelConst().?.findConst(hit.pane_id).?;
        if (pane.pending_frame_id == 0) {
            hover.shown_link = hit;
        }
    }
}

/// An in-flight update may be clicked only when the same target was visible.
/// Example: `if (hover.openable()) gesture.begin(hover.link.?);`
pub fn openable(hover: *const Hover) bool {
    const current = hover.link orelse return false;
    const shown = hover.shown_link orelse return false;
    return current.eql(&shown);
}

/// Seals the overlay bounds with the frame, independently of later pointer motion.
/// Example: `hover.prepare();`
pub fn prepare(hover: *Hover) void {
    hover.prepared_link = hover.link;
    hover.prepared_preview = if (hover.link) |*hit| hit.previewArea() else null;
}

/// Visible previews cover terminal cells until a replacement is delivered.
/// Example: `if (hover.covers(mouse)) return .{ .consumed = true };`
pub fn covers(hover: *const Hover, mouse: client.Mouse) bool {
    const preview = hover.shown_preview orelse return false;
    return preview.contains(mouse.x, mouse.y);
}

/// Presentation publishes only the target captured by that frame's preparation.
/// Example: `hover.present(delivered);`
pub fn present(hover: *Hover, delivered: bool) void {
    if (delivered) {
        hover.shown_link = hover.prepared_link;
        hover.shown_preview = hover.prepared_preview;
    }

    hover.prepared_link = null;
    hover.prepared_preview = null;
    hover.dirty = true;
}

fn assign(hover: *Hover, next: ?Hit, shape: core.PointerShape) void {
    const same = if (hover.link) |*previous| if (next) |*current| previous.eql(current) else false else next == null;
    if (!same) {
        hover.link = next;
        hover.revision +%= 1;
    }

    hover.shape = shape;
}

/// Losing pointer focus removes the highlight and invalidates the cached cell.
/// Example: `hover.clear();`
pub fn clear(hover: *Hover) void {
    hover.event = null;
    hover.cached = null;
    hover.shown_link = null;
    hover.dirty = true;
    hover.assign(null, .default);
}
