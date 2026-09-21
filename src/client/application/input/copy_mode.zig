//! Application boundary for client-owned copy mode.

const types = @import("../../model/types.zig");
const std = @import("std");
const chord = @import("../../input/chord.zig");

pub const Outcome = enum {
    unchanged,
    changed,
    exited,
};
