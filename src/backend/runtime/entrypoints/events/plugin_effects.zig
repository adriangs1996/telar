//! Runtime boundary for authorized effects returned by tap workers.

const std = @import("std");
const agent_identity = @import("../../application/coordinators/root.zig").agent_identity;
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");
const plugins = @import("../../../plugins/root.zig");

pub const schema = core.schema;

pub const Resources = @import("PluginEffectsResources.zig");

pub const RuntimePort = @import("GenericPluginEffectsRuntimePort.zig").Type;

pub const Adapter = @import("GenericPluginEffectsAdapter.zig").Type;

test {
    std.testing.refAllDecls(@This());
}
