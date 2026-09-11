const AgentEvidence = @This();
const core = @import("telar-core");
const source_namespace = @import("effects.zig");
pane: core.schema.PaneId,
state: core.schema.AgentReportState,
confidence: source_namespace.Confidence,
