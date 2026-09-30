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

/// Where in the window a frame stopped.
pub const Route = enum {
    window_draw,
    window_update,
};

/// Reports a capacity error and returns true when the window goes on;
/// returns false for any other error, which the caller fails with.
///
/// ```zig
/// if (!limit_reached.absorb(gui, .window_draw, err)) gui.fail(err);
/// ```
pub fn absorb(gui: *GuiAdapter, route: Route, err: anyerror) bool {
    client.limit_reached.absorb(gui.app, @tagName(route), err, limitOf(gui, err)) catch return false;

    // The notice above is part of what this frame would show, so the
    // window retries only once something after it changes.
    if (route == .window_draw) {
        gui.limited = gui.observation();
    }

    return true;
}

/// Whether the frame the window would draw now is the one that stopped at
/// a limit; drawing it again would stop there again.
/// Example: `if (limit_reached.holds(gui)) return 0;`
pub fn holds(gui: *const GuiAdapter) bool {
    const limited = gui.limited orelse return false;
    return std.meta.eql(limited, gui.observation());
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
