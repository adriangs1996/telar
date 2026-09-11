const CredentialType = @import("Credential.zig");
const types = @import("../agent/types.zig");
const middleware = @import("middleware.zig");
const Event = @This();

credential: CredentialType,
dialect: types.ApiDialect,
phase: middleware.Phase,
protocol: middleware.Protocol,
connection_id: u64,
stream_id: u32 = 0,
status_code: u16 = 0,
observed_at_ms: i64,
