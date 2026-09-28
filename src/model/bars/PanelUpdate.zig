//! A finished render for one opening of a configured panel.
const LocalTime = @import("../state/LocalTime.zig");
const PanelRun = @import("../operations/configuration/PanelRun.zig");
const bar_values = @import("model.zig");
const PanelUpdate = @This();

generation: u64,
run: PanelRun,
content: bar_values.PanelContent,
time: LocalTime,
