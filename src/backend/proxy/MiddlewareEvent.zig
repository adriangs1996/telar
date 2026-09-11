const Event = @This();
const identity = @import("identity.zig");
const dialect_mod = @import("provider/dialect.zig");
const source_namespace = @import("middleware.zig");
credential: identity.Credential,
dialect: dialect_mod.ApiDialect,
phase: source_namespace.Phase,
protocol: source_namespace.Protocol,
connection_id: u64,
stream_id: u32 = 0,
status_code: u16 = 0,
observed_at_ms: i64,
