//! Bounded presentation completion values. They never retain pane pointers.

const std = @import("std");
const schema = @import("telar-core").schema;
const Pane = @import("pane_support.zig").Pane;

pub const PresentationCommit = @import("PresentationCommit.zig");
