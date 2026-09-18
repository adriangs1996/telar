const RouterConfigType = @import("RouterConfig.zig");
/// The adapter's host input source: the client resumes it after transport
/// backpressure, hands it replayed bytes a prompt must decode, and gives it
/// the bindings a reloaded configuration compiled. Native conversation readers
/// can own copy mode without creating a terminal-cell selection.
const HostInputSource = @This();

context: *anyopaque,
resume_read_fn: *const fn (*anyopaque) anyerror!void,
route_prompt_bytes_fn: *const fn (*anyopaque, []const u8) anyerror!void,
adopt_bindings_fn: *const fn (*anyopaque, RouterConfigType) void,
enter_thread_copy_mode_fn: ?*const fn (*anyopaque, @import("telar-core").PaneId) bool = null,
thread_copy_mode_active_fn: ?*const fn (*anyopaque) bool = null,
leave_thread_copy_mode_fn: ?*const fn (*anyopaque) bool = null,

/// Enters the adapter's conversation reader after shared input admission.
/// Unsupported hosts leave all state untouched. The adapter owns cancellation
/// when another pane, editor or modal takes focus.
/// Example: `_ = client.host_input_source.enterThreadCopyMode(pane_id);`
pub fn enterThreadCopyMode(port: HostInputSource, pane_id: @import("telar-core").PaneId) bool {
    const enter = port.enter_thread_copy_mode_fn orelse return false;
    return enter(port.context, pane_id);
}

/// Keeps semantic actions aware of a native reader without exposing its state.
/// Example: `if (port.threadCopyModeActive()) leaveReader();`
pub fn threadCopyModeActive(port: HostInputSource) bool {
    const active = port.thread_copy_mode_active_fn orelse return false;
    return active(port.context);
}

/// Retires native reading before another semantic action. The adapter reports
/// whether it changed state. Example: `_ = port.leaveThreadCopyMode();`
pub fn leaveThreadCopyMode(port: HostInputSource) bool {
    const leave = port.leave_thread_copy_mode_fn orelse return false;
    return leave(port.context);
}

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
