//! Who a captured exchange belongs to and how it travelled.
const core = @import("telar-core");
const types = @import("../../agent/types.zig");
const middleware = @import("../middleware.zig");

pane: Pane,
dialect: types.ApiDialect,
protocol: middleware.Protocol,

const Pane = struct {
    id: core.PaneId,
    generation: u64,
};
