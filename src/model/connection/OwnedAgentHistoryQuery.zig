const core = @import("telar-core");
request_id: core.RequestId,
pane_id: core.PaneId,
pane_generation: u64,
view_generation: u64,
cursor_len: u16,
anchor_len: u16,
anchor_turn_len: u16,
direction: core.agent_history.Direction,

/// Borrows the outbound slot only while serializing its owned cursor bytes.
/// Example: `try core.encodeQueryAgentHistory(buffer, query.view(bytes));`
pub fn view(query: *const @This(), bytes: []const u8) core.QueryAgentHistory {
    return .{ .request_id = query.request_id, .pane_id = query.pane_id, .pane_generation = query.pane_generation, .view_generation = query.view_generation, .cursor = bytes[0..query.cursor_len], .anchor = bytes[query.cursor_len..][0..query.anchor_len], .anchor_turn = bytes[@as(usize, query.cursor_len) + query.anchor_len ..][0..query.anchor_turn_len], .direction = query.direction };
}
