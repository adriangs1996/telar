const ProcessReconciliation = @This();
const source_namespace = @import("observation.zig");
const agent_process = @import("../../../../process/root.zig");
const pane_mod = @import("../../../../pane/root.zig");
pane: *source_namespace.Pane,
probe: agent_process.Probe,
transition: pane_mod.HistoryObservationCompletion,
