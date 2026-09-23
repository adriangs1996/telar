const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const Input = @This();

area: core.Rect,
model: *const data.Model,
/// The active tab's slot in `model.tabs`.
tab: usize,
alignment: data.bar_values.Alignment = .right,
animation_frame: u8 = 0,
