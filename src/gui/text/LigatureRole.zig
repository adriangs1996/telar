//! What a grapheme can do to the shaping of its neighbours in the primary
//! face's ligature lookups. Ordered: a cluster takes the strongest role of
//! its codepoints.
pub const LigatureRole = enum(u2) {
    /// No ligature lookup reads it: it shapes alone and splits runs.
    none,
    /// A lookup reads it around the glyphs it substitutes, never replacing it.
    context,
    /// A lookup substitutes it.
    input,
};
