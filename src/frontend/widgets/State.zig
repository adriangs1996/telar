const core = @import("telar-core");
const client = @import("telar-client");
const State = @This();

scroll: u16 = 0,
total_rows: u16 = 0,
/// The fleet order last computed, with the first sidebar line of each
/// entry, recomputed only when the agents, the workspace list or the
/// focused pane changed.
fleet: [core.max_agent_snapshot_entries]client.FleetEntry = undefined,
fleet_start: [core.max_agent_snapshot_entries]u16 = undefined,
fleet_len: usize = 0,
fleet_agents: u64 = 0,
fleet_workspaces: u64 = 0,
fleet_focus: ?core.PaneId = null,
fleet_valid: bool = false,

pub fn scrollBy(self: *State, rows: i16, viewport_height: u16) bool {
    const max_scroll = self.total_rows -| viewport_height;
    const before = self.scroll;
    if (rows < 0) {
        self.scroll -|= @intCast(-rows);
    } else {
        self.scroll = @min(max_scroll, self.scroll +| @as(u16, @intCast(rows)));
    }
    return before != self.scroll;
}
