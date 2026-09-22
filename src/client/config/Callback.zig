const data = @import("model");
const model = @import("model.zig");
const Callback = @This();

registry_ref: c_int,
expression: bool,
trigger: [model.max_binding_keys]data.Key = @splat(.plain(.escape)),
trigger_len: u8 = 0,
