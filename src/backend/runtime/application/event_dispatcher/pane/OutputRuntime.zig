const IngestTestGateType = @import("../../../IngestTestGate.zig");
const IngestCompletion = @import("../../../entrypoints/events/pane/IngestCompletion.zig");
const Application = @import("../../Application.zig");

application: *Application,
ingest_gate: ?*IngestTestGateType,
inline_ingest: ?IngestCompletion = null,
