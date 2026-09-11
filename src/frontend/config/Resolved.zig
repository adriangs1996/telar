const config_model = @import("model.zig");
const default_bindings = @import("default_bindings.zig");
const Resolved = @This();

bindings: [config_model.max_bindings]default_bindings.Binding = undefined,
len: u16 = 0,

pub fn slice(resolved: *const Resolved) []const default_bindings.Binding {
    return resolved.bindings[0..resolved.len];
}
