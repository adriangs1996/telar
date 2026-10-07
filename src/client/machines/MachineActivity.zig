const data = @import("model");

/// One borrowed runtime replica in the window's global activity view.
slot: u8,
label: []const u8,
model: *data.ClientModel,
connected: bool,
