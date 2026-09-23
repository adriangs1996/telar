//! Borrowed image paths at synchronous protocol boundaries. Async owners copy them.
const Images = @import("AgentImages.zig");
const Paths = @This();

storage: [Images.capacity][]const u8 = @splat(""),
count: u8 = 0,

/// Borrows a validated path. Example: `try paths.append("/tmp/image.png");`
pub fn append(self: *Paths, value: []const u8) !void {
    try Images.validatePath(value);
    if (self.count >= Images.capacity) {
        return error.TooManyAgentImages;
    }

    self.storage[self.count] = value;
    self.count += 1;
}

/// Example: `try writer.write(paths.path(0));`
pub fn path(self: *const Paths, index: usize) []const u8 {
    return self.storage[0..self.count][index];
}

/// Checks manually constructed protocol values too. Example: `try paths.validate();`
pub fn validate(self: *const Paths) !void {
    if (self.count > Images.capacity) {
        return error.TooManyAgentImages;
    }

    for (self.storage[0..self.count]) |value| {
        try Images.validatePath(value);
    }
}
