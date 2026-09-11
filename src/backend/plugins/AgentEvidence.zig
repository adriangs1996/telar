const PaneIdType = @import("telar-core").PaneId;
const AgentReportStateType = @import("telar-core").AgentReportState;
const effects = @import("effects.zig");
const AgentEvidence = @This();

pane: PaneIdType,
state: AgentReportStateType,
confidence: effects.Confidence,
