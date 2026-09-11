const HostCommitType = @import("../../model/HostCommit.zig");
const Effects = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, HostCommitType) anyerror!void,
