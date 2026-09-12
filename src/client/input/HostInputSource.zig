const RouterConfigType = @import("RouterConfig.zig");
/// The adapter's host input source: the client resumes it after transport
/// backpressure, hands it replayed bytes a prompt must decode, and gives it
/// the bindings a reloaded configuration compiled.
const HostInputSource = @This();

context: *anyopaque,
resume_read_fn: *const fn (*anyopaque) anyerror!void,
route_prompt_bytes_fn: *const fn (*anyopaque, []const u8) anyerror!void,
adopt_bindings_fn: *const fn (*anyopaque, RouterConfigType) void,

/// Example: `try client.host_input_source.resumeRead();`.
pub fn resumeRead(port: HostInputSource) !void {
    return port.resume_read_fn(port.context);
}

/// Decodes replayed host bytes for the active prompt.
pub fn routePromptBytes(port: HostInputSource, bytes: []const u8) !void {
    return port.route_prompt_bytes_fn(port.context, bytes);
}

/// Replaces the adapter's compiled bindings after a configuration reload.
/// The reload validated them with the shared keymap checks; an adapter that
/// still cannot compile them keeps its previous bindings.
pub fn adoptBindings(port: HostInputSource, config: RouterConfigType) void {
    port.adopt_bindings_fn(port.context, config);
}
