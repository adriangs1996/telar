const Completion = @This();
const source_namespace = @import("observation.zig");
const history = @import("../../../../history/root.zig");
const agent_process = @import("../../../../process/root.zig");
pane: source_namespace.PaneKey,
stats: history.observer.Stats,
process_probe: agent_process.Probe,
