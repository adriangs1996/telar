const RectType = @import("telar-core").Rect;
const FrameGeometry = @This();

/// Exactly half of the host in both dimensions, rounded down.
outer: RectType,
/// The PTY geometry after reserving a one-cell border.
content: RectType,
