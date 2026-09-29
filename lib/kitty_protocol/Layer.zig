//! The three bands a z-index selects, in paint order.
pub const Layer = enum {
    /// Under cells with a non-default background color.
    below_background,
    /// Over cell backgrounds, under text.
    below_text,
    /// Over text.
    above_text,
};
