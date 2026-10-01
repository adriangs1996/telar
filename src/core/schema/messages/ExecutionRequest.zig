const id = @import("../id.zig");
const ExecutionRequest = @This();

pub const Action = enum(u8) { start, status, input, eof, cancel, forget, list };
pub const max_chunk = 4096;
pub const max_arguments = 64;
pub const max_launch_bytes = 32768;

request_id: id.RequestId = .none,
action: Action,
execution_id: u64,
workspace_id: u64 = 0,
stdout_offset: u64 = 0,
stderr_offset: u64 = 0,
input_offset: u64 = 0,
stdin_open: bool = false,
cwd: []const u8 = "",
arguments: [max_arguments][]const u8 = @splat(""),
argument_count: u8 = 0,
bytes: []const u8 = "",
