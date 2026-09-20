const core = @import("telar-core");

pane_id: core.PaneId,
pane_generation: u64,
attachment_generation: u64,
location: core.TabLocation,
view_generation: u64,
edition_id: u64,

session_bytes: [core.change_review.max_identity_bytes]u8 = undefined,
session_len: u8 = 0,

/// Pins subsequent requests to the exact provider conversation already reviewed.
/// Example: `try operation.setSession(snapshot.session);`
pub fn setSession(self: *@This(), session: []const u8) !void {
    if (session.len > self.session_bytes.len) {
        return error.ChangeReviewSessionTooLarge;
    }
    @memcpy(self.session_bytes[0..session.len], session);
    self.session_len = @intCast(session.len);
}

/// Example: `query.session = operation.sessionSlice();`
pub fn sessionSlice(self: *const @This()) []const u8 {
    return self.session_bytes[0..self.session_len];
}
