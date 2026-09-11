//! Translates runtime-owned pane resources into immutable agent identity.

const PaneType = @import("../../../pane/Pane.zig");
const IdentityType = @import("../../../agent/Identity.zig");
const std = @import("std");

/// Captures an exact pane generation and its process/session identifiers.
/// Example: `const identity = fromPane(runtime_pane);`.
pub fn fromPane(source: *const PaneType) IdentityType {
    return .{
        .key = source.key(),
        .process_id = std.math.cast(u32, source.session.processId()) orelse 0,
        .session_id = source.history_session_id,
    };
}
