//! How much of one component a fitted bar still shows.
pub const FitLevel = enum(u2) {
    full,
    compact,
    hidden,
};
