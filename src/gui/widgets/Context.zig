const data = @import("model");
const core = @import("telar-core");
const workspace_identity = @import("workspace_identity.zig");
const action_module = @import("action.zig");
const std = @import("std");
const HitMap = @import("HitMap.zig");
const BandHitMap = @import("BandHitMap.zig");
const client = @import("telar-client");
const AgentAges = @import("AgentAges.zig");
const SidebarRegions = @import("SidebarRegions.zig");
const Favicons = @import("Favicons.zig");
const ProgressMotions = @import("ProgressMotions.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Context = @This();

hits: *HitMap,
bands: *BandHitMap,
projection: *const client.Projection,
hovered: ?action_module.Action,
/// Last delivered project identity, used only during the empty handoff frame.
presented_workspace: ?core.WorkspaceId = null,
sidebar_regions: ?*const SidebarRegions = null,
ages: ?*const AgentAges = null,
/// Placed workspace favicons; `null` in fixtures without a registry.
favicons: ?*const Favicons = null,
progress: ?*ProgressMotions = null,
/// Where the tab strip records its area for the pointer to test next frame.
tab_strip: ?*Rect = null,
/// Whether the delivered pointer rests on the tab strip.
pointer_in_tabs: bool = false,
/// The chrome's record of the tab the strip is laid out around.
tab_anchor: ?*?core.TabId = null,
/// Where the bar panel records its bounds for the pointer.
bar_panel: ?*Rect = null,
/// Where the bar row records the components it had no room for.
bar_overflow: ?*data.BarOverflow = null,

/// Resolves the navigation highlight without retaining retired pane or tab data.
/// Example: `const selected = context.workspaceId() == workspace;`
pub fn workspaceId(self: *const Context) ?core.WorkspaceId {
    return workspace_identity.navigationId(self.projection, self.presented_workspace);
}

/// Shares one status clock between cards and pane headers.
/// Example: `const seconds = context.statusAge(agent);`
pub fn statusAge(self: *const Context, agent: *const data.Agent) u32 {
    return if (self.ages) |ages| ages.seconds(agent) else agent.statusAgeSeconds();
}

/// Keeps a sidebar paint linear by using the card's known snapshot index.
/// Example: `const seconds = context.statusAgeAt(index);`
pub fn statusAgeAt(self: *const Context, index: usize) u32 {
    return if (self.ages) |ages| ages.secondsAt(index) else self.projection.agents.slice()[index].statusAgeSeconds();
}

/// Compares the delivered hover identity with a semantic control action.
/// Example: `const hovered = context.isHovered(.{ .intent = .toggle_sidebar });`
pub fn isHovered(self: *const Context, action: action_module.Action) bool {
    return if (self.hovered) |value| std.meta.eql(value, action) else false;
}
