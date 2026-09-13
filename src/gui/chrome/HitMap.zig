const core = @import("telar-core");
const Action = @import("action.zig").Action;
const Hit = @import("Hit.zig");
const HitMap = @This();

// One target per visible card line, workspace, tab and pane border. The
// finite table also bounds every pointer lookup independently of text size.
pub const capacity = core.max_panes_per_tab * 6 + core.max_agent_snapshot_entries * 3 + core.max_workspace_list_entries + core.max_tabs_per_workspace + 4;
items: [capacity]Hit = undefined,
len: usize = 0,

/// Rejects overflow rather than publishing a drawn control without a target.
/// Example: `try hits.add(.{ .area = row, .action = action });`
pub fn add(hits: *HitMap, hit: Hit) !void {
    if (hit.area.isEmpty()) {
        return;
    }

    if (hits.len == hits.items.len) {
        return error.ChromeHitCapacityExceeded;
    }

    hits.items[hits.len] = hit;
    hits.len += 1;
}

/// Later targets take precedence, as later quads do.
/// Example: `const action = hits.at(.{ mouse.x, mouse.y });`
pub fn at(hits: *const HitMap, point: [2]u16) ?Action {
    var index = hits.len;
    while (index > 0) {
        index -= 1;
        if (hits.items[index].area.contains(point[0], point[1])) {
            return hits.items[index].action;
        }
    }

    return null;
}
