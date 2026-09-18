const std = @import("std");

io: std.Io,
allocator: std.mem.Allocator,
job: *const @import("Job.zig"),
/// Explicit executable injection for lifecycle tests; production resolves a sibling helper.
executable: ?[]const u8 = null,
timeout_ms: u32 = 8000,
result: anyerror!@import("Image.zig") = error.RendererUnavailable,
