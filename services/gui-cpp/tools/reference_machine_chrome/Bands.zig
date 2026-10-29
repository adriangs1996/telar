const gfx = @import("gfx");
const action_module = @import("action.zig");
const Action = action_module.Action;
const placement_module = @import("BandPlacement.zig");
const BandPlacement = placement_module.BandPlacement;
const record_geometry = @import("record_geometry.zig");
const Bands = @This();
const picker: u8 = 255;

pub fn add(self: *Bands, band: struct { area: gfx.Rect, action: Action, placement: BandPlacement }) void {
    _ = self;

    record_geometry.rectangle(.band, band.area) catch unreachable;
    const target: u8 = switch (band.action.intent) {
        .machine_picker => picker,
        .select_machine => |slot| slot,
    };
    record_geometry.write(target) catch unreachable;
}
