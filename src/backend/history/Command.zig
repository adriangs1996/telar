const Command = @This();
const source_namespace = @import("osc.zig");
bytes: []const u8,
cwd: []const u8,
started_at_ms: i64,
duration_ns: i64,
exit_code: ?i32,
status: source_namespace.Status,
truncated: bool,
/// Bounded raw output tail observed while the command ran; empty unless
/// output capture is enabled.
output: []const u8 = "",
output_truncated: bool = false,
output_observed: u64 = 0,
