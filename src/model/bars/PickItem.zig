//! One pick-list option as a producer hands it over; `value` and `detail`
//! default to the label and to nothing.
const cellgrid = @import("cellgrid");

label: []const u8,
value: ?[]const u8 = null,
detail: []const u8 = "",

/// Optional presentation only; never changes the selected command value.
selected: bool = false,
swatch: ?[3]cellgrid.Color = null,
