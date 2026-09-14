//! Which family a chrome label is set in. Terminal cells never choose; they
//! always use the configured monospace face.
pub const Face = enum(u1) {
    /// The terminal's configured face, advancing one cell per column.
    mono,
    /// Embedded IBM Plex Sans with proportional HarfBuzz advances; `bold`
    /// selects the real SemiBold file instead of synthetic emboldening.
    sans,
};
