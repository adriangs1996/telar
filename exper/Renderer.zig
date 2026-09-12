const Self = @This();

context: *anyopaque,
render_fn: *const fn (*anyopaque, i32) anyerror!void,

/// Publishes a value snapshot without retaining the model. Example: try renderer.render(3);
pub fn render(self: *Self, value: i32) !void {
    try self.render_fn(self.context, value);
}
