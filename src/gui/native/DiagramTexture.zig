//! Borrowed premultiplied RGBA8 pixels, immutable until frame completion.
//! Empty slots have all-zero fields; populated slots use nonzero content versions.
const std = @import("std");

pub const slot_count = 8;
pub const max_side = 4096;
pub const max_pixels = 4 * 1024 * 1024;
pub const max_frame_pixels = 8 * 1024 * 1024;

pub const DiagramTexture = extern struct {
    pixels: ?[*]const u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    version: u64 = 0,

    /// Checks shape and quota before any pixel access. Example: `try texture.pixelCount()`.
    pub fn pixelCount(texture: DiagramTexture) !u32 {
        if (texture.pixels == null) {
            if (texture.width != 0 or texture.height != 0 or texture.version != 0) {
                return error.InvalidDiagramTexture;
            }

            return 0;
        }

        if (texture.width == 0 or texture.height == 0 or texture.width > max_side or texture.height > max_side or texture.version == 0) {
            return error.InvalidDiagramTexture;
        }

        const pixels = texture.width * texture.height;
        if (pixels > max_pixels) {
            return error.DiagramTextureTooLarge;
        }

        return pixels;
    }

    /// Validates all slots without reading their pixels. Example: `try DiagramTexture.validate(&frame.diagrams)`.
    pub fn validate(textures: *const [slot_count]DiagramTexture) !void {
        var total: u32 = 0;
        for (textures) |texture| {
            total += try texture.pixelCount();
        }

        if (total > max_frame_pixels) {
            return error.DiagramFrameTooLarge;
        }
    }
};

test "diagram descriptors reject malformed dimensions and per-frame overflow without reading pixels" {
    const pixel = [_]u8{ 0, 0, 0, 0 };
    var slots: [slot_count]DiagramTexture = @splat(.{});
    try DiagramTexture.validate(&slots);
    for ([_]DiagramTexture{
        .{ .width = 1 },
        .{ .version = 1 },
        .{ .pixels = &pixel },
        .{ .pixels = &pixel, .width = 1, .height = 1 },
        .{ .pixels = &pixel, .width = 4097, .height = 1, .version = 1 },
        .{ .pixels = &pixel, .width = 1, .height = std.math.maxInt(u32), .version = 1 },
    }) |invalid| {
        try std.testing.expectError(error.InvalidDiagramTexture, invalid.pixelCount());
    }

    try std.testing.expectError(error.DiagramTextureTooLarge, (DiagramTexture{ .pixels = &pixel, .width = 4096, .height = 1025, .version = 1 }).pixelCount());
    slots[0] = .{ .pixels = &pixel, .width = 4096, .height = 1024, .version = 1 };
    slots[7] = slots[0];
    try DiagramTexture.validate(&slots);
    slots[1] = .{ .pixels = &pixel, .width = 1, .height = 1, .version = 1 };
    try std.testing.expectError(error.DiagramFrameTooLarge, DiagramTexture.validate(&slots));
    slots[0] = .{};
    try DiagramTexture.validate(&slots);
}
