const Role = @import("telar-client").SyntaxRole;
const limits = @import("limits.zig");

roles: [limits.source_bytes]Role = undefined,
id: u64 = 0,
status: anyerror!void = {},
