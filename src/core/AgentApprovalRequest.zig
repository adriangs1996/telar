const agent_thread = @import("agent_thread.zig");

id: u64,
kind: agent_thread.ApprovalKind,
description: [agent_thread.max_approval_bytes]u8 = @splat(0),
description_len: u16 = 0,

/// Example: `drawText(approval.text());`
pub fn text(approval: *const @This()) []const u8 {
    return approval.description[0..approval.description_len];
}
