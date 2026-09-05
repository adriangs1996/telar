//! Translates runtime-owned pane resources into immutable agent identity.

const std = @import("std");
const agent = @import("../../../agent/root.zig");
const pane = @import("../../../pane/root.zig");

/// Captures an exact pane generation and its process/session identifiers.
/// Example: `const identity = fromPane(runtime_pane);`.
pub fn fromPane(source: *const pane.Pane) agent.Identity {
    return .{
        .key = source.key(),
        .process_id = std.math.cast(u32, source.session.processId()) orelse 0,
        .session_id = source.history_session_id,
    };
}
