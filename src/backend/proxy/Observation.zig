const PaneKeyType = @import("../pane/PaneKey.zig");
const types = @import("../agent/types.zig");
const middleware = @import("middleware.zig");
const Observation = @This();

pane: PaneKeyType,
dialect: types.ApiDialect,
phase: middleware.Phase,
protocol: middleware.Protocol,
connection_id: u64,
stream_id: u32 = 0,
status_code: u16 = 0,
observed_at_ms: i64,
