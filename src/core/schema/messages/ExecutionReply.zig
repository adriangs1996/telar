const id = @import("../id.zig");
const ExecutionRequest = @import("ExecutionRequest.zig");
const ExecutionReply = @This();

pub const State = enum(u8) { starting, running, exited, failed };
request_id: id.RequestId = .none,
execution_id: u64,
workspace_id: u64 = 0,
state: State = .starting,
exit_code: i32 = 0,
stdout_offset: u64 = 0,
stderr_offset: u64 = 0,
stdout_total: u64 = 0,
stderr_total: u64 = 0,
input_offset: u64 = 0,
input_available: u64 = 0,
failure_len: u8 = 0,
failure: [128]u8 = @splat(0),
stdin_open: bool = false,
stdout_len: u16 = 0,
stderr_len: u16 = 0,
stdout: [ExecutionRequest.max_chunk]u8 = @splat(0),
stderr: [ExecutionRequest.max_chunk]u8 = @splat(0),
