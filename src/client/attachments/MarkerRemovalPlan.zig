//! How dismissing one preview removes its marker from the agent's prompt:
//! the keys to send, nothing when no plan can reach the marker from the
//! cursor, or the limit the plan stopped at, which the client flow reports.
const core = @import("telar-core");
const model_data = @import("model");

pub const MarkerRemovalPlan = union(enum) {
    planned: model_data.MarkerRemoval,
    /// The marker is not on screen, or the cursor shares no row with it.
    unreachable_marker,
    limited: core.LimitReach,
};
