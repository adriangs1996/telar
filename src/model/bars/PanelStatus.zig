//! Whether an open panel has content to show yet.
pub const PanelStatus = enum(u2) {
    /// Opened, waiting for its first render.
    loading,
    ready,
    /// The last render failed; older content, if any, is still shown.
    failed,
};
