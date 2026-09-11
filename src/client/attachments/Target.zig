/// The placeholder's first word. Claude and Codex word-wrap `[Image #N]` at
/// the space after it, so a marker may end on the row below its head.
const Target = @This();
const source_namespace = @import("types.zig");
pane_id: source_namespace.schema.PaneId,
pane_generation: u64,

pub fn validate(target: Target) !void {
    if (target.pane_id == .invalid or target.pane_generation == 0) {
        return error.InvalidAttachmentTarget;
    }
}
