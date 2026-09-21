//! Application command for acknowledging one delivered pane frame.

pub const FrameAckResult = union(enum) {
    acknowledged: u64,
    stale,
};
