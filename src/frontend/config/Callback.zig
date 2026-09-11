const Callback = @This();
const source_namespace = @import("generation_support.zig");
registry_ref: c_int,
expression: bool,
trigger: [source_namespace.max_binding_keys]source_namespace.keybind.Key = @splat(.plain(.escape)),
trigger_len: u8 = 0,
