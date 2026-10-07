//! Composition root for one long-lived backend runtime.

const std = @import("std");
const Options = @import("Options.zig");
const Runtime = @import("Runtime.zig");

/// Runs one runtime instance until a stop event or fatal runtime error.
/// `options` is borrowed for the duration of the call.
///
/// ```zig
/// try serve(io, gpa, .{
///     .endpoint = "/tmp/telar.sock",
///     .environment = environment,
/// });
/// ```
pub fn serve(io: std.Io, gpa: std.mem.Allocator, options: Options) !void {
    // SAFETY: Runtime.init constructs resources, loop and model in place; failure returns before run or deferred deinit.
    var runtime: Runtime = undefined;
    try runtime.init(.{
        .dependencies = .{ .io = io, .allocator = gpa },
        .options = options,
    });
    defer runtime.deinit();

    try runtime.run();
}
