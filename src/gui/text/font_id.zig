//! Stable atlas-local identities; a glyph index is meaningful only within its face.
pub const Id = enum(u3) {
    primary,
    text,
    symbols,
    sans,
    sans_semibold,

    /// Fallback ink is fitted into the requesting cell; natural faces keep
    /// their own advances and bearings. Example: `if (id.fitted()) { ... }`
    pub fn fitted(id: Id) bool {
        return id == .text or id == .symbols;
    }
};
