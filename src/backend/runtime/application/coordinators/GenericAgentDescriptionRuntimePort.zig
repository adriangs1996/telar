const source_namespace = @import("agent_description.zig");
const agent_mod = @import("../../../agent/root.zig");
/// Defines generator startup, durable title projection, and client delivery
/// bound by the runtime instance.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        start: *const fn (*Context, source_namespace.description.Command, source_namespace.description.Job) anyerror!void,
        persist: *const fn (*Context, agent_mod.DescriptionFinished) void,
        pump_clients: *const fn (*Context) void,
    };
}
