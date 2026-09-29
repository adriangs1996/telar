//! One pointer target in a chrome band, in device pixels.
const action_module = @import("action.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const BandPlacement = @import("BandPlacement.zig").BandPlacement;
area: Rect,
action: action_module.Action,
placement: BandPlacement = .primary,
