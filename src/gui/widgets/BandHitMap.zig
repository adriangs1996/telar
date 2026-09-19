//! Fixed pointer targets for the pixel bands: the sidebar toggle, every
//! project row or fallback workspace control, every tab, the new-tab control,
//! one target per visible agent card and pane frame extension, and the sidebar
//! resize handle. Cell targets stay in `HitMap`; this table is looked up first
//! because pixel targets need not align with the grid.
const core = @import("telar-core");
const Action = @import("action.zig").Action;
const BandHit = @import("BandHit.zig");
const Bands = @import("Bands.zig");
const BandHitMap = @This();

pub const capacity = 1 + core.max_workspace_list_entries + 1 + core.max_tabs_per_workspace + 1 + core.max_agent_snapshot_entries + 1 + 4 + core.max_panes_per_tab;
items: [capacity]BandHit = undefined,
len: usize = 0,

/// Rejects overflow rather than publishing a drawn control without a target.
/// Example: `try bands.add(.{ .area = pill, .action = .{ .intent = .{ .select_workspace = id } } });`
pub fn add(hits: *BandHitMap, hit: BandHit) !void {
    if (hit.area.width <= 0 or hit.area.height <= 0) {
        return;
    }

    if (hits.len == hits.items.len) {
        return error.ChromeHitCapacityExceeded;
    }

    hits.items[hits.len] = hit;
    hits.len += 1;
}

/// Later targets take precedence, as later quads do.
/// Example: `const action = hits.at(.{ event.x, event.y });`
pub fn at(hits: *const BandHitMap, point: [2]f64) ?Action {
    var index = hits.len;
    while (index > 0) {
        index -= 1;
        if (Bands.within(hits.items[index].area, point[0], point[1])) {
            return hits.items[index].action;
        }
    }

    return null;
}

/// The first target carrying `intent`, for tests that click by identity.
/// Example: `const tab = hits.find(.{ .select_tab = id }) orelse return error.Missing;`
pub fn find(hits: *const BandHitMap, intent: @import("telar-client").Intent) ?BandHit {
    for (hits.items[0..hits.len]) |hit| {
        if (hit.action == .intent and @import("std").meta.eql(hit.action.intent, intent)) {
            return hit;
        }
    }

    return null;
}
