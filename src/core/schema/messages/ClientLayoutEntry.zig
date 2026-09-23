const TabLocation = @import("../TabLocation.zig");
const ClientLayoutEntry = @This();

location: TabLocation,
workspace_active: bool,
node_count: usize,
