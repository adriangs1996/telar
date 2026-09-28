const std = @import("std");
const WorktreeProbe = @import("../../workspace/WorktreeProbe.zig");
const WorktreeProbeJob = @This();

io: std.Io,
request: WorktreeProbe,
