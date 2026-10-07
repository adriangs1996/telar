const input = @import("input/Input.zig");
const Viewport = @import("Viewport.zig");

/// Reasons for the GUI loop to update its model. Wakes are coalesced hints;
/// the caller must inspect current state rather than count notifications.
pub const Event = union(enum) {
    close,
    wake,
    input: input.Input,
    resize: Viewport,
    /// Refresh period of the current display in nanoseconds.
    display_interval: u64,
};
