const CompositionResult = @This();
const RenderStats = @import("RenderStats.zig");
const source_namespace = @import("multiplexer.zig");
stats: RenderStats,
commit: source_namespace.PresentationCommit,
