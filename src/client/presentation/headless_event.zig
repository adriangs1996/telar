const data = @import("model");
const HeadlessCompletion = @import("HeadlessCompletion.zig");
pub const Message = union(enum) {
    server: *const data.RuntimeMessage,
    key: data.Key,
    completed: HeadlessCompletion,
};
