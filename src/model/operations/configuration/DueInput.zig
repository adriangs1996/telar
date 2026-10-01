const BarConfiguration = @import("../../bars/BarConfiguration.zig");
const PanelSource = @import("../../bars/PanelSource.zig").PanelSource;
const DueInput = @This();

generation: u64,
configuration: *const BarConfiguration,
now_ns: u64,
/// The open panel's source, when a configured panel is open.
panel_source: ?*const PanelSource = null,
