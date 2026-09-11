//! Header-transform configuration frozen before concurrent traffic begins.

const std = @import("std");
const middleware = @import("../middleware.zig");
const provider = @import("../provider/root.zig");

pub const Io = std.Io;

pub const View = @import("View.zig");

pub const Configuration = @import("Configuration.zig");

var test_transformer_context: u8 = 0;

fn preserveHeaders(_: *anyopaque, _: middleware.Transformation) middleware.TransformStatus {
    return .preserve;
}

fn testTransformer() middleware.Transformer {
    return .{ .context = &test_transformer_context, .transform = preserveHeaders };
}

test "custom transforms are visible before serving begins" {
    var configuration = try Configuration.init();

    try configuration.add(std.testing.io, testTransformer());

    const view = configuration.view();
    try std.testing.expect(view.has_custom_transformers);
}

test "serving freezes transforms and rejects a second start" {
    const io = std.testing.io;
    var configuration = try Configuration.init();

    try configuration.beginServing(io);

    try std.testing.expectError(error.ProxyAlreadyRunning, configuration.add(io, testTransformer()));
    try std.testing.expectError(error.ProxyAlreadyRunning, configuration.beginServing(io));
}
