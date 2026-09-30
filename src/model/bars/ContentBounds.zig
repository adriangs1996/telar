//! How much one component list holds: components, text bytes, click
//! actions and sparkline samples. Bar slots and panels hold different
//! amounts of the same shape.
const ContentBounds = @This();

nodes: u8,
text: u16,
actions: u8,
samples: u16,
