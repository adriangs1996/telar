const Exchange = @This();
const core = @import("telar-core");
const proxy = @import("../proxy/root.zig");
const Half = @import("Half.zig");
id: u64,
generation: u64,
pane: core.schema.PaneId,
pane_generation: u64,
host: []const u8,
protocol: proxy.ObservationProtocol,
dialect: proxy.ApiDialect,
connection_id: u64,
stream_id: u32,
method: []const u8,
target: []const u8,
started_at_ms: i64,
request: ?Half,
response: ?Half,
