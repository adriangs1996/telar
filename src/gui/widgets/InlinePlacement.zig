//! Where an inline component is painted, and at which fitted level.
const data = @import("model");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const InlinePlacement = @This();

bounds: Rect,
level: data.FitLevel = .full,
