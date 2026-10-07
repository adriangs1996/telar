const PaneKey = @import("../../pane/PaneKey.zig");
const Stats = @import("../../history/Stats.zig");
const Probe = @import("../../process/Probe.zig");

pane: PaneKey,
stats: Stats,
process_probe: Probe,
