//! One admitted input's bounded opportunity to present newer pane cells.
const core = @import("telar-core");
const client = @import("telar-client");
const Pane = client.PresentationCommit.PaneCommit;
const Grace = @This();

pane: Pane,
started_ns: u64,
frames_left: u32 = core.pace.default_input_frames,

/// A matching frame must follow both input admission and prior preparation.
/// Example: `if (grace.includes(visible_pane)) considerInputGrace();`
pub fn includes(grace: *const Grace, pane: Pane) bool {
    return pane.attached and pane.pane_id == grace.pane.pane_id and
        pane.attachment_generation == grace.pane.attachment_generation and
        pane.frame_id > grace.pane.frame_id;
}

/// Applies this input's grace to the shared window cadence without mutation.
/// Example: `const scoped = grace.scoped(window_pacer);`
pub fn scoped(grace: *const Grace, cadence: core.Pacer) core.Pacer {
    var result = cadence;
    result.noteInput(grace.started_ns);
    result.input_frames_left = grace.frames_left;
    return result;
}

/// Charges only a newer frame captured in an admitted presentation commit.
/// Example: `grace.record(committed_pane, prepared_pacer);`
pub fn record(grace: *Grace, pane: Pane, prepared: core.Pacer) void {
    grace.pane = pane;
    grace.frames_left = prepared.input_frames_left;
}
