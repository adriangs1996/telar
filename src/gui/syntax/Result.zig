const data = @import("model");
const client = @import("telar-client");
const limits = @import("limits.zig");

roles: [limits.source_bytes]data.role.Role = undefined,
id: u64 = 0,
status: anyerror!void = {},
