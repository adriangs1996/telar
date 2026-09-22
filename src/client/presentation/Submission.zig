const data = @import("model");
const ObservationType = @import("Observation.zig");
const GeometryType = @import("Geometry.zig");
const Submission = @This();

observation: ObservationType,
commit: data.PresentationCommit,
geometry: GeometryType = .{},
media_pending: bool = false,
