//! Bounded local image references. Only same-machine clients may submit paths.
const std = @import("std");
const Images = @This();

pub const capacity = 4;
pub const max_path_bytes = 1024;

storage: [capacity][max_path_bytes]u8 = undefined,
lengths: [capacity]u16 = @splat(0),
count: u8 = 0,

/// Owns a UTF-8 absolute PNG path without retaining caller memory.
/// Example: `try images.append("/private/tmp/image.png");`
pub fn append(images: *Images, value: []const u8) !void {
    try validatePath(value);
    if (images.count >= capacity) {
        return error.TooManyAgentImages;
    }

    @memcpy(images.storage[images.count][0..value.len], value);
    images.lengths[images.count] = @intCast(value.len);
    images.count += 1;
}

/// Example: `const path = images.path(0);`
pub fn path(images: *const Images, index: usize) []const u8 {
    std.debug.assert(index < images.count);
    return images.storage[index][0..images.lengths[index]];
}

/// Borrows paths only until this value changes. Example: `request.images = images.view();`
pub fn view(images: *const Images) @import("AgentImagePaths.zig") {
    var result: @import("AgentImagePaths.zig") = .{ .count = images.count };
    for (0..images.count) |index| {
        result.storage[index] = images.path(index);
    }

    return result;
}

/// Copies a validated borrowed list for asynchronous ownership. Example: `prompt.images = try Images.copy(request.images);`
pub fn copy(paths: @import("AgentImagePaths.zig")) !Images {
    try paths.validate();
    var images: Images = .{};
    for (paths.storage[0..paths.count]) |value| {
        try images.append(value);
    }

    return images;
}

/// Removes one reference, preserving the order of the remaining images.
/// Example: `_ = images.remove(0);`
pub fn remove(images: *Images, index: usize) bool {
    if (index >= images.count) {
        return false;
    }

    var next = index;
    while (next + 1 < images.count) : (next += 1) {
        images.storage[next] = images.storage[next + 1];
        images.lengths[next] = images.lengths[next + 1];
    }

    images.count -= 1;
    images.lengths[images.count] = 0;
    return true;
}

/// Validates even values constructed without append. Example: `try images.validate();`
pub fn validate(images: *const Images) !void {
    if (images.count > capacity) {
        return error.TooManyAgentImages;
    }

    for (images.lengths[0..images.count], 0..) |len, index| {
        if (len > max_path_bytes) {
            return error.InvalidAgentImage;
        }

        try validatePath(images.storage[index][0..len]);
    }
}

/// Applies the local image reference policy. Example: `try Images.validatePath(path);`
pub fn validatePath(value: []const u8) !void {
    if (value.len == 0 or value.len > max_path_bytes or value[0] != '/' or !std.mem.endsWith(u8, value, ".png") or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidAgentImage;
    }

    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return error.InvalidAgentImage;
        }
    }
}

test "image references own paths and reject malformed or excessive attachments" {
    var images: Images = .{};
    var source = "/tmp/a.png".*;
    try images.append(&source);
    source[5] = 'b';
    try std.testing.expectEqualStrings("/tmp/a.png", images.path(0));
    for (0..capacity - 1) |_| {
        try images.append("/tmp/b.png");
    }

    try std.testing.expectError(error.TooManyAgentImages, images.append("/tmp/c.png"));
    try std.testing.expect(images.remove(0));
    try std.testing.expectEqualStrings("/tmp/b.png", images.path(0));
    try std.testing.expect(!images.remove(capacity));
    for ([_][]const u8{ "relative.png", "/tmp/x\x00.png", "/tmp/x\n.png", "/tmp/a.jpg", "" }) |invalid| {
        try std.testing.expectError(error.InvalidAgentImage, images.append(invalid));
    }

    images.count = capacity + 1;
    try std.testing.expectError(error.TooManyAgentImages, images.validate());
}
