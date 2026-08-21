//! telar - a terminal UI core.
//!
//! Six pieces, and the split between them is the design:
//!
//!   `ui`        geometry, cells, the buffer, hit testing, focus.  Portable,
//!               and knows nothing about terminals - which is what lets a
//!               layout be tested without one.
//!   `term`      the diff, the escape sequences it becomes, the input parser,
//!               the clipboard.  Bytes in and bytes out; not a syscall in it.
//!   `pace`      when to draw and what to throw away first.  No clock: time
//!               arrives as a number, so a burst is tested without sleeping.
//!   `edit`      a text field.  Byte offsets, cluster movements, and the
//!               discipline of never confusing the two.
//!   `select`    dragging text off the screen so it can be copied.
//!   `platform`  the only file that knows which operating system this is.
//!
//! `blit` sits apart: it is the adapter to libghostty-vt, and the only place
//! that knows both halves.  Everything above it would build in a project with
//! no terminal emulator in it at all.

pub const ui = @import("ui.zig");
pub const term = @import("term.zig");
pub const pace = @import("pace.zig");
pub const edit = @import("edit.zig");
pub const select = @import("select.zig");
pub const platform = @import("platform.zig");
pub const blit = @import("blit.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
