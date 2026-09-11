const echo_trace = @import("echo_trace.zig");
const std = @import("std");
const Record = @This();

ns: u64,
tag: echo_trace.Tag,
cpu_ns: if (echo_trace.cpu_enabled) u64 else void = if (echo_trace.cpu_enabled) 0 else {},
thread: if (echo_trace.cpu_enabled) std.Thread.Id else void = if (echo_trace.cpu_enabled) 0 else {},
