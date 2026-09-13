pub const Message = union(enum) {
    server: *const @import("../connection/RuntimeMessage.zig"),
    key: @import("../input/Key.zig"),
    completed: @import("HeadlessCompletion.zig"),
};
