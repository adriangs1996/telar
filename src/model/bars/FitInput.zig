//! What an adapter measured before fitting its bar row: the slots in visual
//! order and the width of every component at each level, in the adapter's
//! own unit (pixels in the GUI, cells in the TUI).
const model = @import("model.zig");
const FitInput = @This();

pub const max_slots = 4;

slots: [max_slots]?*const model.Content = @splat(null),
/// A leaf's full width; a group's own chrome (padding and mark) without
/// its children.
full: [max_slots][model.max_bar_nodes]f32 = @splat(@splat(0)),
/// A meter's width without its track. Other kinds have no compact form.
compact: [max_slots][model.max_bar_nodes]f32 = @splat(@splat(0)),
available: f32,
/// Between two top-level components of one slot, separator included.
unit_gap: f32 = 0,
/// Between a group's chrome and each of its visible children.
child_gap: f32 = 0,
/// Between two slots that both show something.
slot_gap: f32 = 0,
/// The `+N` chip and its gap, paid once when anything is hidden.
overflow_width: f32 = 0,
