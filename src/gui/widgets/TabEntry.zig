//! One tab of the strip: its slot in the tabs table and its painted bounds.
const Rect = @import("../render/Rect.zig");

index: usize,
bounds: Rect,
