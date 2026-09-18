const std = @import("std");
const HitMap = @import("HitMap.zig");
const BandHitMap = @import("BandHitMap.zig");
const Action = @import("action.zig").Action;
const client = @import("telar-client");
const AgentAges = @import("AgentAges.zig");
const Context = @This();

hits: *HitMap,
bands: *BandHitMap,
projection: *const client.Projection,
hovered: ?Action,
/// Last delivered project identity, used only during the empty handoff frame.
presented_workspace: ?@import("telar-core").WorkspaceId = null,
sidebar_regions: ?*const @import("SidebarRegions.zig") = null,
ages: ?*const AgentAges = null,
/// Placed workspace favicons; `null` in fixtures without a registry.
favicons: ?*const @import("Favicons.zig") = null,
progress: ?*@import("ProgressMotions.zig") = null,

/// Resolves the navigation highlight without retaining retired pane or tab data.
/// Example: `const selected = context.workspaceId() == workspace;`
pub fn workspaceId(context: *const Context) ?@import("telar-core").WorkspaceId {
    return @import("workspace_identity.zig").navigationId(context.projection, context.presented_workspace);
}

/// Shares one status clock between cards and pane headers.
/// Example: `const seconds = context.statusAge(agent);`
pub fn statusAge(context: *const Context, agent: *const client.Agent) u32 {
    return if (context.ages) |ages| ages.seconds(agent) else agent.statusAgeSeconds();
}

/// Keeps a sidebar paint linear by using the card's known snapshot index.
/// Example: `const seconds = context.statusAgeAt(index);`
pub fn statusAgeAt(context: *const Context, index: usize) u32 {
    return if (context.ages) |ages| ages.secondsAt(index) else context.projection.agents.slice()[index].statusAgeSeconds();
}

/// Compares the delivered hover identity with a semantic control action.
/// Example: `const hovered = context.isHovered(.{ .intent = .toggle_sidebar });`
pub fn isHovered(context: *const Context, action: Action) bool {
    return if (context.hovered) |value| std.meta.eql(value, action) else false;
}
