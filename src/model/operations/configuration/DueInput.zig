const BarConfiguration = @import("../../bars/BarConfiguration.zig");
const model = @import("../../bars/model.zig");
const DueInput = @This();

generation: u64,
configuration: *const BarConfiguration,
now_ns: u64,
/// The open panel's source, when a configured panel is open.
panel_source: ?*const model.Source = null,
