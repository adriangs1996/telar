//! Application query for copying text from one attached pane.

pub const CopySelectionResult = union(enum) {
    copied: []const u8,
    pane_not_attached,
    unavailable,
    too_large,
};
