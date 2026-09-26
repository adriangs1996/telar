//! Which panel a client shows above its bottom bar.
pub const PanelTarget = union(enum) {
    none,
    /// A panel declared in `client.panels`, by its index.
    configured: u8,
    /// The components the fitted bar had no room for.
    overflow,
};
