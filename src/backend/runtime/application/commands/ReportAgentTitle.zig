const PaneKeyType = @import("../../../pane/PaneKey.zig");
const ReportAgentTitle = @This();

pane: PaneKeyType,
/// Empty clears an earlier agent title.
title: []const u8,
