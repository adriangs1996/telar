const TabLocationType = @import("../TabLocation.zig");
const ClientLayoutEntry = @This();

location: TabLocationType,
workspace_active: bool,
node_count: usize,
