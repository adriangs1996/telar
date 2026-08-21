//! The disposable side of telar.
//!
//! The frontend owns the real terminal, frame pacing and interactive UI state.
//! It consumes core data and never reaches into backend process state.

const core = @import("telar-core");

pub const ui = @import("ui.zig");
pub const select = core.select;
pub const term = @import("term.zig");
pub const pace = @import("pace.zig");
pub const edit = @import("edit.zig");
pub const platform = @import("platform.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
