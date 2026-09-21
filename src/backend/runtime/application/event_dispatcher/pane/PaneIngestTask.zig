const IngestTestGateType = @import("../../../IngestTestGate.zig");
const OutputIngest = @import("../../../entrypoints/events/pane/OutputIngest.zig");

ingest: OutputIngest,
gate: ?*IngestTestGateType,
