//! A request to open a panel: which one, from which component, with the
//! source it runs while open.
const BarComponent = @import("BarComponent.zig");
const PanelTarget = @import("PanelTarget.zig").PanelTarget;
const bar_values = @import("model.zig");
const PanelOpening = @This();

target: PanelTarget,
anchor: ?BarComponent = null,
/// The configured panel's source; null for the overflow list.
source: ?*const bar_values.Source = null,
now_ns: u64,
