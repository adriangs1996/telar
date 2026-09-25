/// Whether a damage scan counts its cell comparisons. Counting is resolved
/// at compile time, so a scan that does not count carries no counter in its
/// comparison loop.
pub const Counting = enum {
    off,
    comparisons,
};
