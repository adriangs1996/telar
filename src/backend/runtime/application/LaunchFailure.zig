const model = @import("../../history/model.zig");
const LaunchFailure = @This();

shell: []const u8,
phase: model.LaunchPhase,
cause: anyerror,
