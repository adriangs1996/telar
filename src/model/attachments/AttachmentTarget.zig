const core = @import("telar-core");
/// The placeholder's first word. Claude and Codex word-wrap `[Image #N]` at
/// the space after it, so a marker may end on the row below its head.
const Target = @This();

pane_id: core.PaneId,
pane_generation: u64,

pub fn validate(self: Target) !void {
    if (self.pane_id == .invalid or self.pane_generation == 0) {
        return error.InvalidAttachmentTarget;
    }
}
