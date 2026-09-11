const TestProxyObservation = @This();
const types = @import("types.zig");
const source_namespace = @import("tracker_support.zig");
dialect: types.ApiDialect,
phase: source_namespace.ProxyPhase,
observed_at_ms: i64,
