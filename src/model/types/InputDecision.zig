const InputKeys = @import("../config/InputKeys.zig");
const InputPaste = @import("../config/InputPaste.zig");

pub const InputDecision = union(enum) {
    consume,
    forward_binding: InputKeys,
    keys: InputKeys,
    paste: InputPaste,
};
