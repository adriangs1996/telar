const Observation = @This();
const source_namespace = @import("root.zig");
const middleware = @import("middleware.zig");
pane: source_namespace.PaneKey,
dialect: middleware.ApiDialect,
phase: source_namespace.ObservationPhase,
protocol: source_namespace.ObservationProtocol,
connection_id: u64,
stream_id: u32 = 0,
status_code: u16 = 0,
observed_at_ms: i64,
