//! Application policy for one streamed host paste owned by a pane.

const PanePasteSessionType = @import("../../model/PanePasteSession.zig");
const std = @import("std");

pub const Boundary = enum {
    start,
    finish,
};

pub const Delivery = union(enum) {
    marker: struct {
        session: PanePasteSessionType,
        boundary: Boundary,
    },
    content: struct {
        session: PanePasteSessionType,
        /// Borrowed only for the synchronous delivery effect.
        text: []const u8,
    },
};

pub const Outcome = enum {
    applied,
    unavailable,
    ignored,
};
