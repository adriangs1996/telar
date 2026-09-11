const std = @import("std");
const Case = @This();

name: []const u8,
work_per_op: u64,
work_unit: []const u8,
payload_bytes_per_op: u64 = 0,
p99_budget_ns: u64 = std.time.ns_per_ms,
