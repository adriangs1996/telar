const std = @import("std");
const core = @import("telar-core");
const ExecutionPipes = @This();

pub const retained_bytes = 1024 * 1024;
pub const retention_limit = core.Limit.declare("executions.retained_bytes", "bytes per stream", retained_bytes);
pub const input_bytes = 64 * 1024;

// Transport storage shared with one worker. The runtime never waits on this
// lock: a contended request is retried by its client. No I/O holds the lock.
guard: std.atomic.Mutex = .unlocked,
cancel: std.atomic.Value(bool) = .init(false),
eof: std.atomic.Value(bool) = .init(false),
started: std.atomic.Value(bool) = .init(false),
stdout: [retained_bytes]u8 = undefined,
stderr: [retained_bytes]u8 = undefined,
stdout_total: u64 = 0,
stderr_total: u64 = 0,
input: [input_bytes]u8 = undefined,
input_read: u64 = 0,
input_written: u64 = 0,
cwd: []u8,
arguments: [][]const u8,
environ: std.process.Environ,
id: u64,

/// Releases buffers after the worker joined. Example: `pipes.destroy(gpa);`.
pub fn destroy(self: *ExecutionPipes, gpa: std.mem.Allocator) void {
    gpa.free(self.cwd);
    for (self.arguments) |argument| {
        gpa.free(argument);
    }

    gpa.free(self.arguments);
    gpa.destroy(self);
}
