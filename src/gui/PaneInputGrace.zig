//! One admitted input's bounded opportunity to present newer pane cells.
const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const Grace = @This();

pane: data.PresentationCommit.PaneCommit,
started_ns: u64,
frames_left: u32 = core.pace.default_input_frames,

/// A matching frame must follow both input admission and prior preparation.
/// Example: `if (grace.includes(visible_pane)) considerInputGrace();`
pub fn includes(self: *const Grace, pane: data.PresentationCommit.PaneCommit) bool {
    return pane.attached and pane.pane_id == self.pane.pane_id and
        pane.attachment_generation == self.pane.attachment_generation and
        pane.frame_id > self.pane.frame_id;
}

/// Applies this input's grace to the shared window cadence without mutation.
/// Example: `const scoped = grace.scoped(window_pacer);`
pub fn scoped(self: *const Grace, cadence: core.Pacer) core.Pacer {
    var result = cadence;
    result.noteInput(self.started_ns);
    result.input_frames_left = self.frames_left;
    return result;
}

/// Charges only a newer frame captured in an admitted presentation commit.
/// Example: `grace.record(committed_pane, prepared_pacer);`
pub fn record(self: *Grace, pane: data.PresentationCommit.PaneCommit, prepared: core.Pacer) void {
    self.pane = pane;
    self.frames_left = prepared.input_frames_left;
}
