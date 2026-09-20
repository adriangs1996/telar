const core = @import("telar-core");
const PaneKey = @import("../pane/PaneKey.zig");
pane: PaneKey,
provider: core.AgentProvider,
session: [core.change_review.max_identity_bytes]u8 = undefined,
session_len: u8 = 0,

pub fn init(pane: PaneKey, provider: core.AgentProvider, session: []const u8) !@This() {
    if (provider == .unknown or session.len == 0 or session.len > core.change_review.max_identity_bytes) {
        return error.InvalidReviewOwner;
    }
    var result: @This() = .{ .pane = pane, .provider = provider, .session_len = @intCast(session.len) };
    @memcpy(result.session[0..session.len], session);
    return result;
}

pub fn sessionSlice(self: *const @This()) []const u8 {
    return self.session[0..self.session_len];
}
