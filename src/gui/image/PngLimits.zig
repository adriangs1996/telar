//! Bounds a PNG must satisfy before any pixel buffer is allocated.
const PngLimits = @This();

/// Largest width or height accepted.
max_side: u32 = 4096,
/// Largest width times height accepted; the decoded RGBA is four times it.
max_pixels: u32 = 1 << 20,
