//! One owned hover target. Pointer movement within a cell does no text scanning.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const GuiClient = @import("../GuiClient.zig");
const Event = @import("../native/InputEvent.zig").InputEvent;
const Hit = @import("LinkHit.zig");
const Hover = @This();

event: ?Event = null,
cell: ?[2]u16 = null,
mods: u32 = 0,
version: ?client.Version = null,
shape: core.PointerShape = .default,
link: ?Hit = null,
revision: u64 = 0,
dirty: bool = true,

/// Copies native coordinates for re-evaluation after output, resize or modifiers.
/// Example: `hover.observe(event);`
pub fn observe(hover: *Hover, event: Event) void {
    if (event.code == 7) {
        hover.clear();
        return;
    }

    hover.event = event;
    hover.event.?.text = null;
}

/// Reuses the cached cell until model state or delivered controls change.
/// Example: `hover.refresh(gui);`
pub fn refresh(hover: *Hover, gui: *const GuiClient) void {
    const event = hover.event orelse return;
    var moved = event;
    moved.code = 6;
    const mouse = gui.input.pointer.geometry.resolve(moved) orelse {
        hover.assign(null, .default);
        hover.cell = null;
        return;
    };
    const cell: [2]u16 = .{ mouse.x, mouse.y };
    const version = gui.app.model.version();
    if (!hover.dirty and std.meta.eql(hover.cell, @as(?[2]u16, cell)) and hover.mods == event.mods and std.meta.eql(hover.version, @as(?client.Version, version))) {
        return;
    }

    hover.cell = cell;
    hover.mods = event.mods;
    hover.version = version;
    hover.dirty = false;
    const target = @import("hover_target.zig").resolve(gui, mouse, event.mods);
    hover.assign(target.link, target.shape);
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
    hover.cell = null;
    hover.dirty = true;
    hover.assign(null, .default);
}
