const IngestTestGateType = @import("../../../IngestTestGate.zig");
const IngestCompletion = @import("../../../entrypoints/events/pane/IngestCompletion.zig");
const RuntimeModel = @import("../../../RuntimeModel.zig");

model: *RuntimeModel,
ingest_gate: ?*IngestTestGateType,
inline_ingest: ?IngestCompletion = null,
