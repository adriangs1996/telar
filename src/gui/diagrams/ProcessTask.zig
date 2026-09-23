const std = @import("std");
const Job = @import("Job.zig");
const Image = @import("Image.zig");

io: std.Io,
allocator: std.mem.Allocator,
job: *const Job,
/// Explicit executable injection for lifecycle tests; production resolves a sibling helper.
executable: ?[]const u8 = null,
timeout_ms: u32 = 8000,
result: anyerror!Image = error.RendererUnavailable,
