const core = @import("telar-core");
/// Input state only the adapter holds: it decodes replayed host bytes for a
/// prompt, and native conversation readers own copy mode without creating a
/// terminal-cell selection.
const ThreadExpansion = @import("ThreadExpansion.zig");
const HostInputSource = @This();

set_thread_expansion_fn: ?*const fn (*anyopaque, ThreadExpansion) anyerror!void = null,
context: *anyopaque,
route_prompt_bytes_fn: *const fn (*anyopaque, []const u8) anyerror!void,
enter_thread_copy_mode_fn: ?*const fn (*anyopaque, core.PaneId) bool = null,
thread_copy_mode_active_fn: ?*const fn (*anyopaque) bool = null,
leave_thread_copy_mode_fn: ?*const fn (*anyopaque) bool = null,

/// Enters the adapter's conversation reader after shared input admission.
/// Unsupported hosts leave all state untouched. The adapter owns cancellation
/// when another pane, editor or modal takes focus.
/// Example: `_ = client.host_input_source.enterThreadCopyMode(pane_id);`
pub fn enterThreadCopyMode(self: HostInputSource, pane_id: core.PaneId) bool {
    const enter = self.enter_thread_copy_mode_fn orelse return false;
    return enter(self.context, pane_id);
}

/// Keeps semantic actions aware of a native reader without exposing its state.
/// Example: `if (port.threadCopyModeActive()) leaveReader();`
pub fn threadCopyModeActive(self: HostInputSource) bool {
    const active = self.thread_copy_mode_active_fn orelse return false;
    return active(self.context);
}

/// Retires native reading before another semantic action. The adapter reports
/// whether it changed state. Example: `_ = port.leaveThreadCopyMode();`
pub fn leaveThreadCopyMode(self: HostInputSource) bool {
    const leave = self.leave_thread_copy_mode_fn orelse return false;
    return leave(self.context);
}

/// Decodes replayed host bytes for the active prompt.
pub fn routePromptBytes(self: HostInputSource, bytes: []const u8) !void {
    return self.route_prompt_bytes_fn(self.context, bytes);
}

/// Sets one visible native disclosure without emulating input. Example: `try port.setThreadExpansion(request);`
pub fn setThreadExpansion(self: HostInputSource, request: ThreadExpansion) !void {
    const set = self.set_thread_expansion_fn orelse return error.ThreadDisclosureUnsupported;
    try set(self.context, request);
}
