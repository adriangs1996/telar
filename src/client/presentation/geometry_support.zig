//! Owned pane-coordinate authority. Widget hit maps remain adapter-owned.
const std = @import("std");
const schema = @import("telar-core").schema;
const workspace = @import("../workspace/root.zig");
const presentation = @import("root.zig");

pub const Geometry = @import("Geometry.zig");
