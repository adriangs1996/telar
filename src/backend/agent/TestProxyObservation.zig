const types = @import("types.zig");
const TestProxyObservation = @This();

dialect: types.ApiDialect,
phase: types.ProxyPhase,
observed_at_ms: i64,
