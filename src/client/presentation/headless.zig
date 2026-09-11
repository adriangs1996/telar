//! Controllable presentation for contract tests. No terminal, GPU or event loop.
const std = @import("std");
const core = @import("telar-core");
const presentation = @import("root.zig");
pub const lifecycle = presentation.lifecycle;
pub const schema = core.schema;

pub const cell_capacity = 16 * 1024;
pub const Frame = @import("Frame.zig");

pub const Adapter = @import("Adapter.zig");
