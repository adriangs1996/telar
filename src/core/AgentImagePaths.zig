//! Borrowed image paths at synchronous protocol boundaries. Async owners copy them.
const Images = @import("AgentImages.zig");
const Paths = @This();

storage: [Images.capacity][]const u8 = @splat(""),
count: u8 = 0,

/// Borrows a validated path. Example: `try paths.append("/tmp/image.png");`
pub fn append(paths: *Paths, value: []const u8) !void {
    try Images.validatePath(value);
    if (paths.count >= Images.capacity) {
        return error.TooManyAgentImages;
    }

    paths.storage[paths.count] = value;
    paths.count += 1;
}

/// Example: `try writer.write(paths.path(0));`
pub fn path(paths: *const Paths, index: usize) []const u8 {
    return paths.storage[0..paths.count][index];
}

/// Checks manually constructed protocol values too. Example: `try paths.validate();`
pub fn validate(paths: *const Paths) !void {
    if (paths.count > Images.capacity) {
        return error.TooManyAgentImages;
    }

    for (paths.storage[0..paths.count]) |value| {
        try Images.validatePath(value);
    }
}
