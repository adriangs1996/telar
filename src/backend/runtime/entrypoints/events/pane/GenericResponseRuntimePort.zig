const Write = @import("ResponseWrite.zig");
/// Defines the async writer and lifecycle effects supplied by the runtime.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ .start = start, .collect = collect };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        start: *const fn (*Context, Write) anyerror!void,
        collect: *const fn (*Context) void,
    };
}
