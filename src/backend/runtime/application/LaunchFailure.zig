const LaunchFailure = @This();
const history = @import("../../history/root.zig");
shell: []const u8,
phase: history.LaunchPhase,
cause: anyerror,
