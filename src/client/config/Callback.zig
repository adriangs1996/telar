const data = @import("model");
const Callback = @This();

registry_ref: c_int,
expression: bool,
trigger: [data.config_values.max_binding_keys]data.Key = @splat(.plain(.escape)),
trigger_len: u8 = 0,
