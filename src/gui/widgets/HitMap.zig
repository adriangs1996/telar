const action = @import("action.zig");
const core = @import("telar-core");
const Hit = @import("Hit.zig");
const HitMap = @This();

// One target per visible card line, workspace, tab and pane border. The
// finite table also bounds every pointer lookup independently of text size.
pub const capacity = core.max_panes_per_tab * 6 + core.max_agent_snapshot_entries * 3 + core.max_workspace_list_entries + core.max_tabs_per_workspace + 4;
pub const limit = core.Limit.declare("chrome.hit_map_capacity", "cell targets", capacity);
items: [capacity]Hit = undefined,
len: usize = 0,
/// Targets left out because the table was full; the window reports
/// `chrome.hit_map_capacity`.
dropped: usize = 0,

/// Records a cell target. A full table keeps the targets it holds and
/// counts the rest as dropped, so the frame still draws.
/// Example: `hits.add(.{ .area = row, .action = action });`
pub fn add(self: *HitMap, hit: Hit) void {
    if (hit.area.isEmpty()) {
        return;
    }

    if (self.len == self.items.len) {
        self.dropped += 1;
        return;
    }

    self.items[self.len] = hit;
    self.len += 1;
}

/// Later targets take precedence, as later quads do.
/// Example: `const action = hits.at(.{ mouse.x, mouse.y });`
pub fn at(self: *const HitMap, point: [2]u16) ?action.Action {
    var index = self.len;
    while (index > 0) {
        index -= 1;
        if (self.items[index].area.contains(point[0], point[1])) {
            return self.items[index].action;
        }
    }

    return null;
}
