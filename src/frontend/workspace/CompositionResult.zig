const client = @import("telar-client");
const RenderStats = @import("RenderStats.zig");
const CompositionResult = @This();

stats: RenderStats,
commit: client.PresentationCommit,
