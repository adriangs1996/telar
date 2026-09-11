const ObservationType = @import("Observation.zig");
const PresentationCommitType = @import("../panes/PresentationCommit.zig");
const GeometryType = @import("Geometry.zig");
const Submission = @This();

observation: ObservationType,
commit: PresentationCommitType,
geometry: GeometryType = .{},
media_pending: bool = false,
