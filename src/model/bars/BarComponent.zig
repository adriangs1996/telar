//! One component of the bar, by position and index. A click names the
//! component it landed on, and a panel remembers the component it was opened
//! from so adapters can draw it above that component.
const model = @import("model.zig");
const BarComponent = @This();

position: model.Position,
node: u8,
