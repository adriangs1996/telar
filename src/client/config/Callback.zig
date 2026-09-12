const model = @import("model.zig");
const KeyType = @import("../input/Key.zig");
const Callback = @This();

registry_ref: c_int,
expression: bool,
trigger: [model.max_binding_keys]KeyType = @splat(.plain(.escape)),
trigger_len: u8 = 0,
