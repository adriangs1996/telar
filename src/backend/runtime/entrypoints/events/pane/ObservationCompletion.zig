const PaneKeyType = @import("../../../../pane/PaneKey.zig");
const StatsType = @import("../../../../history/Stats.zig");
const ProbeType = @import("../../../../process/Probe.zig");
const Completion = @This();

pane: PaneKeyType,
stats: StatsType,
process_probe: ProbeType,
