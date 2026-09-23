const data = @import("model");
const Observation = @import("Observation.zig");
const Geometry = @import("Geometry.zig");
const Submission = @This();

observation: Observation,
commit: data.PresentationCommit,
geometry: Geometry = .{},
media_pending: bool = false,
