const TextRasterContext = @This();
const std = @import("std");
const frontend = @import("telar-frontend");
const width = 480;
const height = 80;

gpa: std.mem.Allocator,
rasterizer: frontend.text_rasterizer.Rasterizer,
pixels: []u8,

fn init(gpa: std.mem.Allocator) !TextRasterContext {
    var rasterizer = try frontend.text_rasterizer.Rasterizer.init();
    errdefer rasterizer.deinit();
    try rasterizer.setPixelHeight(15);
    const pixels = try gpa.alloc(u8, width * height * 4);
    @memset(pixels, 32);
    return .{ .gpa = gpa, .rasterizer = rasterizer, .pixels = pixels };
}

fn deinit(context: *TextRasterContext) void {
    context.gpa.free(context.pixels);
    context.rasterizer.deinit();
}
