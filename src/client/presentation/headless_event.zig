const data = @import("model");
pub const Message = union(enum) {
    server: *const data.RuntimeMessage,
    key: data.Key,
    completed: @import("HeadlessCompletion.zig"),
};
