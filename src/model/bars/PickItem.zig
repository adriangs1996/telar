//! One pick-list option as a producer hands it over; `value` and `detail`
//! default to the label and to nothing.
label: []const u8,
value: ?[]const u8 = null,
detail: []const u8 = "",
