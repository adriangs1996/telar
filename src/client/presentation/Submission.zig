const Submission = @This();
const presentation = @import("root.zig");
const panes = @import("../panes/root.zig");
observation: presentation.Observation,
commit: panes.PresentationCommit,
geometry: presentation.Geometry = .{},
media_pending: bool = false,
