//! Which configured panel an `open_panel` action toggles, and the bar
//! component it was opened from, if any.
const data = @import("model");
const PanelRequest = @This();

index: u8,
anchor: ?data.BarComponent = null,
