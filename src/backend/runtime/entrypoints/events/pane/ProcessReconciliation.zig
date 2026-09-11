const PaneType = @import("../../../../pane/Pane.zig");
const ProbeType = @import("../../../../process/Probe.zig");
const HistoryObservationCompletionType = @import("../../../../pane/HistoryObservationCompletion.zig");
const ProcessReconciliation = @This();

pane: *PaneType,
probe: ProbeType,
transition: HistoryObservationCompletionType,
