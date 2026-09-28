request_id: u64,
target_id: u64,
generation: u64,
status: Status,
operation: Operation = .read,
text: []const u8 = "",

pub const Status = enum(u2) { success, unavailable, too_large, cancelled };
pub const Operation = enum { read, write };
