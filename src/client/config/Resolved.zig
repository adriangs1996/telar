const data = @import("model");
const default_bindings = @import("default_bindings.zig");
const Resolved = @This();

bindings: [data.config_values.max_bindings]default_bindings.Binding = undefined,
len: u16 = 0,

pub fn slice(self: *const Resolved) []const default_bindings.Binding {
    return self.bindings[0..self.len];
}
