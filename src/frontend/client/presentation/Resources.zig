const StateType = @import("State.zig");
const kitty_delivery = @import("../../graphics/kitty_delivery.zig");
const std = @import("std");
const Resources = @This();

view: *StateType,
graphics_store: *kitty_delivery.Store,
writer: *std.Io.Writer,
