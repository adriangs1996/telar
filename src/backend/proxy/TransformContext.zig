const core = @import("telar-core");
const types = @import("../agent/types.zig");
const middleware = @import("middleware.zig");
const TransformContext = @This();

pane_id: core.PaneId,
pane_generation: u64,
dialect: types.ApiDialect,
protocol: middleware.Protocol,
direction: middleware.Direction,
kind: middleware.HeaderKind,
connection_id: u64,
stream_id: u32,
