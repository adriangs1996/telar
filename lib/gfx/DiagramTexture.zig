//! Borrowed premultiplied RGBA8 pixels, immutable until frame completion.
//! Empty slots have all-zero fields; populated slots use nonzero content versions.
const gfx = @import("root.zig");
const quad = gfx.Quad;

pub const max_side = 4096;
pub const max_pixels = 4 * 1024 * 1024;
/// The diagrams' 8 Mi pixels and the image previews' sheet and modal copy.
pub const max_frame_pixels = 8 * 1024 * 1024 + 256 * 1024 + 2 * 1024 * 1024;

pub const DiagramTexture = extern struct {
    pixels: ?[*]const u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    version: u64 = 0,

    /// Checks shape and quota before any pixel access. Example: `try texture.pixelCount()`.
    pub fn pixelCount(self: DiagramTexture) !u32 {
        if (self.pixels == null) {
            if (self.width != 0 or self.height != 0 or self.version != 0) {
                return error.InvalidDiagramTexture;
            }

            return 0;
        }

        if (self.width == 0 or self.height == 0 or self.width > max_side or self.height > max_side or self.version == 0) {
            return error.InvalidDiagramTexture;
        }

        const pixels = self.width * self.height;
        if (pixels > max_pixels) {
            return error.DiagramTextureTooLarge;
        }

        return pixels;
    }

    /// Validates all slots without reading their pixels. Example: `try DiagramTexture.validate(&frame.diagrams)`.
    pub fn validate(textures: *const [quad.diagram_slot_count]DiagramTexture) !void {
        var total: u32 = 0;
        for (textures) |texture| {
            total += try texture.pixelCount();
        }

        if (total > max_frame_pixels) {
            return error.DiagramFrameTooLarge;
        }
    }
};
