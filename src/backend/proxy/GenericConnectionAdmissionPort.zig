const source_namespace = @import("connection_admission.zig");
/// Defines listener, worker-group, slot, and socket operations supplied by the
/// proxy service. A successful `start` transfers both the stream and its slot
/// to the worker; every other path leaves them with the admission runner.
///
/// ```zig
/// const port: Port(Context, Stream) = .{ ... };
/// ```
pub fn Type(comptime Context: type, comptime Stream: type) type {
    return struct {
        accept: *const fn (*Context) anyerror!Stream,
        acquire: *const fn (*Context) bool,
        start: *const fn (*Context, *source_namespace.Io.Group, Stream) anyerror!void,
        release: *const fn (*Context) void,
        close: *const fn (*Context, Stream) void,
        cancel: *const fn (*Context, *source_namespace.Io.Group) void,
    };
}
