//! One pointer target in a chrome band, in device pixels.
const action_module = @import("action.zig");
const Rect = @import("../render/Rect.zig");
area: Rect,
action: action_module.Action,
