const Resolved = @This();
const config_model = @import("model.zig");
const source_namespace = @import("default_bindings.zig");
bindings: [config_model.max_bindings]source_namespace.Binding = undefined,
len: u16 = 0,

pub fn slice(resolved: *const Resolved) []const source_namespace.Binding {
    return resolved.bindings[0..resolved.len];
}
