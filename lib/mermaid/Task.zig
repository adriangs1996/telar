//! One owned render: the helper runs until exit, the deadline or cancellation.
const std = @import("std");
const Image = @import("Image.zig");
const Request = @import("Request.zig");

io: std.Io,
allocator: std.mem.Allocator,
request: Request,
/// Tried in order; a later helper is spawned only when an earlier one does not exist.
executables: []const []const u8,
timeout_ms: u32 = 8000,
result: anyerror!Image = error.RendererUnavailable,
