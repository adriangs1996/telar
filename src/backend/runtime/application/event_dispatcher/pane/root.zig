//! Composition root for pane runtime-event adapters.

const std = @import("std");
const pane_io = @import("io.zig");
const pane_pipeline = @import("pipeline.zig");
const pane_projection = @import("projection.zig");

pub const Dependencies = @import("GenericPaneDependencies.zig").Type;

pub const Dispatcher = @import("GenericPaneDispatcher.zig").Type;

test {
    std.testing.refAllDecls(@This());
}
