const Role = @import("telar-client").SyntaxRole;
const limits = @import("limits.zig");

pub const Status = enum { empty, pending, running, ready, failed };

source: [limits.source_bytes]u8 = undefined,
roles: [limits.source_bytes]Role = undefined,
len: usize = 0,
hash: u64 = 0,
id: u64 = 0,
frame: u64 = 0,
status: Status = .empty,
