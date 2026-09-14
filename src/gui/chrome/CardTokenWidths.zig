//! Measured widths of the card tokens that can be dropped, in device pixels.
//! Every field is a measurement; `resolve` in `card_degradation.zig` decides.

/// Inner width of the card.
available: f32,
/// Project glyph plus workspace label on row 1.
workspace: f32,
age: f32,
/// Status glyph, with the elapsed time while working.
status: f32,
/// The provider mark, including its gap.
mark: f32,
/// The least the last event may keep before it is dropped.
event_min: f32 = 48,
gap: f32 = 6,
