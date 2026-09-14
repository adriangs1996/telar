//! Pixel sizing policy. Content uses the intrinsic measurement supplied by a widget.
pub const Length = union(enum) {
    fixed: f32,
    content,
    /// An equal share of the space left after fixed/content sizes and fill
    /// minimums. Each maximum caps its share without redistributing excess.
    fill,
};
