const PaneIdType = @import("telar-core").PaneId;
const middleware = @import("../proxy/middleware.zig");
const types = @import("../agent/types.zig");
const Half = @import("Half.zig");
const Exchange = @This();

id: u64,
generation: u64,
pane: PaneIdType,
pane_generation: u64,
host: []const u8,
protocol: middleware.Protocol,
dialect: types.ApiDialect,
connection_id: u64,
stream_id: u32,
method: []const u8,
target: []const u8,
started_at_ms: i64,
request: ?Half,
response: ?Half,
