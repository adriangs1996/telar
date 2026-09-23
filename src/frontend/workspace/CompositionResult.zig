const data = @import("model");
const RenderStats = @import("RenderStats.zig");
const CompositionResult = @This();

stats: RenderStats,
commit: data.PresentationCommit,
