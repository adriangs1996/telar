const PixelFormat = @import("PixelFormat.zig").PixelFormat;
const BlendFactor = @import("BlendFactor.zig").BlendFactor;
const BlendOperation = @import("BlendOperation.zig").BlendOperation;

vertex: []const u8,
fragment: []const u8,
format: PixelFormat,
blend: ?Blend = null,

const Blend = struct {
    source_rgb: BlendFactor,
    destination_rgb: BlendFactor,
    source_alpha: BlendFactor,
    destination_alpha: BlendFactor,
    rgb_operation: BlendOperation = .add,
    alpha_operation: BlendOperation = .add,
};
