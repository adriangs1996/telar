//! Header-transform configuration frozen before concurrent traffic begins.

const TransformationType = @import("../Transformation.zig");
const middleware = @import("../middleware.zig");
const TransformerType = @import("../Transformer.zig");
const Configuration = @import("Configuration.zig");
const std = @import("std");

var test_transformer_context: u8 = 0;

fn preserveHeaders(_: *anyopaque, _: TransformationType) middleware.TransformStatus {
    return .preserve;
}

fn testTransformer() TransformerType {
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
