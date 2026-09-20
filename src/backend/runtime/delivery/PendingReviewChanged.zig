const core = @import("telar-core");
pane_id: core.PaneId,
pane_generation: u64,
latest_edition_id: u64,
session: [core.change_review.max_identity_bytes]u8 = undefined,
session_len: u8,

pub fn view(self: *const @This()) core.ChangeReviewChanged {
    return .{ .pane_id = self.pane_id, .pane_generation = self.pane_generation, .latest_edition_id = self.latest_edition_id, .session = self.session[0..self.session_len] };
}
