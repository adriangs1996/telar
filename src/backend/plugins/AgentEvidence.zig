const core = @import("telar-core");
const effects = @import("effects.zig");
const AgentEvidence = @This();

pane: core.PaneId,
state: core.AgentReportState,
confidence: effects.Confidence,
