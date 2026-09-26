//! A meter track: its box, its value and marker in thousandths, and its tone.
const data = @import("model");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const TrackPaint = @This();

bounds: Rect,
value: u16,
tone: data.Tone,
marker: ?u16 = null,
marker_height: f32 = 0,
