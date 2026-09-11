const AgentSnapshotCommitType = @import("../../model/AgentSnapshotCommit.zig");
const AgentSnapshotDelivery = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, *const AgentSnapshotCommitType) anyerror!void,
