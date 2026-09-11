const PaneIdType = @import("telar-core").PaneId;
const types = @import("../agent/types.zig");
const middleware = @import("middleware.zig");
const TransformContext = @This();

pane_id: PaneIdType,
pane_generation: u64,
dialect: types.ApiDialect,
protocol: middleware.Protocol,
direction: middleware.Direction,
kind: middleware.HeaderKind,
connection_id: u64,
stream_id: u32,
