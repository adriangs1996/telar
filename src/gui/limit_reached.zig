//! Limit reached, window side: the safety net that keeps a limit error in a
//! frame's draw or update from closing the window. The window keeps its
//! previous frame, the limit is reported through the client's
//! `limit_reached`, and drawing waits until what the frame shows or the
//! viewport changes. Meanwhile the title names the limit, because a frame
//! that keeps failing cannot show its notice. Any other error still closes
//! the window by propagating out of the Zig loop.

const core = @import("telar-core");
const RetainedCells = @import("render/RetainedCells.zig");
const GlyphAtlas = @import("text/GlyphAtlas.zig");

/// The cells one grid may hold, which a window measuring more cuts to.
pub const cell_count_limit = core.Limit.declare("protocol.max_cell_count", "cells", core.max_cell_count);

/// Room for the title's suffix: its words and a full limit name.
pub const title_suffix_bytes = 32 + core.Limit.max_name_bytes;

/// Where in the window a frame stopped.
pub const Route = enum {
    window_draw,
    window_update,
};

/// The named limit behind an error the window's own code raises.
pub fn limitOf(err: anyerror) ?core.Limit {
    return switch (err) {
        error.ScreenTooLarge => cell_count_limit,
        error.NativeCellBudgetExceeded => core.Limit.declare("render.retained_max_cells", "cells", RetainedCells.max_cells),
        error.AtlasFull => GlyphAtlas.side_limit,
        else => null,
    };
}
