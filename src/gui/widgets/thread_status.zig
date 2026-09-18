//! User-facing activity comes from typed runtime events, never inferred prose.
const core = @import("telar-core");

/// Returns the live operation, falling back to the authoritative thread state.
/// Example: `const label = thread_status.text(snapshot);`
pub fn text(snapshot: ?*const core.AgentThreadSnapshot) []const u8 {
    const value = snapshot orelse return "Connecting";
    switch (value.status) {
        .starting => return "Connecting",
        .blocked => return "Needs your approval",
        .failed => return "Error",
        else => {},
    }

    var child_active = false;
    var index = value.items().len;
    while (index > 0) {
        index -= 1;
        const item = value.items()[index];
        if (item.status != .running and item.status != .pending) {
            continue;
        }

        if (item.kind == .subagent) {
            child_active = true;
            continue;
        }

        if (item.role == .user) {
            continue;
        }

        return switch (item.kind) {
            .reasoning => "Thinking",
            .command => "Running command",
            .file_change => "Editing files",
            .web_search => "Searching the web",
            .dispatch => "Delegating tasks",
            .mcp, .dynamic_tool => "Using tools",
            .plan => "Planning",
            .message => "Writing response",
            else => "Working",
        };
    }

    if (child_active) {
        return "Waiting for agents";
    }

    return if (value.status == .working) "Working" else if (value.items().len > 0) "Completed" else "Ready";
}

/// Idle and settled threads never keep the native renderer awake.
/// Example: `if (thread_status.active(snapshot)) animateLabel();`
pub fn active(snapshot: ?*const core.AgentThreadSnapshot) bool {
    const value = snapshot orelse return true;
    if (value.status == .starting or value.status == .working) {
        return true;
    }

    if (value.status != .ready) {
        return false;
    }

    for (value.items()) |item| {
        if (item.kind == .subagent and (item.status == .pending or item.status == .running)) {
            return true;
        }
    }

    return false;
}
