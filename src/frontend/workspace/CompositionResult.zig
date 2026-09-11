const RenderStats = @import("RenderStats.zig");
const PresentationCommitType = @import("telar-client").PresentationCommit;
const CompositionResult = @This();

stats: RenderStats,
commit: PresentationCommitType,
