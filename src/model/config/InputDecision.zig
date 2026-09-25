const InputKeys = @import("InputKeys.zig");
const InputPaste = @import("InputPaste.zig");

pub const InputDecision = union(enum) {
    consume,
    forward_binding: InputKeys,
    keys: InputKeys,
    paste: InputPaste,
};
