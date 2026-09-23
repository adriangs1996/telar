const ImageKey = @import("ImageKey.zig");
const Image = @import("Image.zig");
const Rect = @import("Rect.zig");
const std = @import("std");
/// A placement relative to a pane's cell grid. Source values are pixels in the
/// decoded image; offsets are pixels inside the anchor cell.
const Placement = @This();

key: ImageKey,
/// Runtime-unique within the pane. The child-facing placement ID remains
/// separate because anonymous placements all have child ID zero.
virtual_id: u64,
placement_id: u32,
x: i32,
y: i32,
source_x: u32 = 0,
source_y: u32 = 0,
source_width: u32 = 0,
source_height: u32 = 0,
columns: u32 = 0,
rows: u32 = 0,
offset_x: u32 = 0,
offset_y: u32 = 0,
z_index: i32 = 0,

pub fn sourceRect(self: Placement, image: Image) !Rect {
    if (self.virtual_id == 0) {
        return error.InvalidPlacementIdentity;
    }
    if (!std.meta.eql(self.key, image.key)) {
        return error.PlacementImageMismatch;
    }
    if (self.source_x >= image.width or self.source_y >= image.height) {
        return error.InvalidSourceRectangle;
    }
    const width = if (self.source_width == 0)
        image.width - self.source_x
    else
        self.source_width;
    const height = if (self.source_height == 0)
        image.height - self.source_y
    else
        self.source_height;
    const right = std.math.add(u32, self.source_x, width) catch
        return error.InvalidSourceRectangle;
    const bottom = std.math.add(u32, self.source_y, height) catch
        return error.InvalidSourceRectangle;
    if (width == 0 or height == 0 or right > image.width or bottom > image.height) {
        return error.InvalidSourceRectangle;
    }
    return .{
        .x = self.source_x,
        .y = self.source_y,
        .width = width,
        .height = height,
    };
}
