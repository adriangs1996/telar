//! Application policy for delivering one committed sidebar layout.

const std = @import("std");

pub const Event = enum {
    project_view,
    invalidate_graphics,
    pane_geometry,
};
