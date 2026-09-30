//! Limit reached, window side: the safety net that keeps a capacity error
//! in a frame's draw or update from closing the window. The window keeps
//! its previous frame, the limit is reported through the client's
//! `limit_reached`, and drawing waits until something the frame shows
//! changes. Any other error still closes the window through `gui.fail`.
//! See `docs/flows/limit-reached.md`.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const GuiAdapter = @import("GuiAdapter.zig");
const Registry = @import("widgets/interaction/Registry.zig");
const RetainedCells = @import("render/RetainedCells.zig");
const GlyphAtlas = @import("text/GlyphAtlas.zig");
const native = @import("native/native.zig");

/// Where in the window a frame stopped.
pub const Route = enum {
    window_draw,
    window_update,
};

/// Reports a capacity error and returns true when the window goes on;
/// returns false for any other error, which the caller fails with.
///
/// ```zig
/// if (!limit_reached.absorb(gui, .window_update, err)) gui.fail(err);
/// ```
pub fn absorb(gui: *GuiAdapter, route: Route, err: anyerror) bool {
    client.limit_reached.absorb(gui.app, @tagName(route), err, limitOf(gui, err)) catch return false;
    return true;
}

/// `absorb` for a frame drawn for `viewport`, which the window then holds
/// until what it shows or the viewport changes.
///
/// ```zig
/// if (!limit_reached.absorbFrame(gui, viewport, err)) gui.fail(err);
/// ```
pub fn absorbFrame(gui: *GuiAdapter, viewport: native.Viewport, err: anyerror) bool {
    if (!absorb(gui, .window_draw, err)) {
        return false;
    }

    // The notice above is part of what this frame would show, so the
    // window retries only once something after it changes.
    gui.limited = .{
        .observation = gui.observation(),
        .viewport = viewport,
    };
    return true;
}

/// Whether what the window would show is still the frame that stopped at a
/// limit, so asking for a draw would stop there again.
/// Example: `const due = needs and !limit_reached.holds(gui);`
pub fn holds(gui: *const GuiAdapter) bool {
    const limited = gui.limited orelse return false;
    return std.meta.eql(limited.observation, gui.observation());
}

/// `holds` for a draw at `viewport`: a new viewport measures again.
/// Example: `if (limit_reached.holdsFrame(gui, viewport)) return 0;`
pub fn holdsFrame(gui: *const GuiAdapter, viewport: native.Viewport) bool {
    const limited = gui.limited orelse return false;
    return std.meta.eql(limited.viewport, viewport) and holds(gui);
}

/// The named limit behind an error the window's own code raises.
fn limitOf(gui: *const GuiAdapter, err: anyerror) ?core.Limit {
    return switch (err) {
        error.ScreenTooLarge => .{
            .name = "protocol.max_cell_count",
            .noun = "cells",
            .value = core.max_cell_count,
        },
        error.NativeCellBudgetExceeded => .{
            .name = "render.retained_max_cells",
            .noun = "cells",
            .value = RetainedCells.max_cells,
        },
        error.NativeQuadBudgetExceeded => .{
            .name = "render.frame_quad_budget",
            .noun = "quads",
            .value = gui.renderer.quads.limit orelse 0,
        },
        error.WidgetTargetCapacityExceeded => .{
            .name = "gui.widgets.registry_capacity",
            .noun = "widget targets",
            .value = Registry.capacity,
        },
        error.AtlasFull => .{
            .name = "text.glyph_atlas_side",
            .noun = "texels per side",
            .value = GlyphAtlas.side,
        },
        else => null,
    };
}
