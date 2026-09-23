const frontend = @import("telar-frontend");
const std = @import("std");
const TextRasterContext = @This();

pub const width = 480;
pub const height = 80;

gpa: std.mem.Allocator,
rasterizer: frontend.Rasterizer,
pixels: []u8,

pub fn init(gpa: std.mem.Allocator) !TextRasterContext {
    var rasterizer = try frontend.Rasterizer.init();
    errdefer rasterizer.deinit();
    try rasterizer.setPixelHeight(15);
    const pixels = try gpa.alloc(u8, width * height * 4);
    @memset(pixels, 32);
    return .{ .gpa = gpa, .rasterizer = rasterizer, .pixels = pixels };
}

pub fn deinit(self: *TextRasterContext) void {
    self.gpa.free(self.pixels);
    self.rasterizer.deinit();
}
