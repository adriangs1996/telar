const client = @import("telar-client");
const action_module = @import("action.zig");
const Action = action_module.Action;
const placement_module = @import("BandPlacement.zig");
const BandPlacement = placement_module.BandPlacement;
const Bands = @import("Bands.zig");
const Context = @This();

projection: struct { machines: ?*const client.Machines },
bands: *Bands,

pub fn isHoveredAt(self: *const Context, action: Action, placement: BandPlacement) bool {
    _ = self;
    _ = action;
    _ = placement;

    return false;
}
