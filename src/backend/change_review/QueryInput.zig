const Group = @import("Group.zig");
const Edition = @import("Edition.zig");
const core = @import("telar-core");
group: *const Group,
edition: *const Edition,
query: core.QueryChangeReview,
