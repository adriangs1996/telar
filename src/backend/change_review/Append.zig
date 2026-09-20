const core = @import("telar-core");
const Group = @import("Group.zig");
group: *Group,
identity: [32]u8,
source: core.change_review.Source,
patch: []const u8,
