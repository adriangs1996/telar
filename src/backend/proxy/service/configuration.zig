//! Header-transform configuration frozen before concurrent traffic begins.

const std = @import("std");
const middleware = @import("../middleware.zig");
const provider = @import("../provider/root.zig");

const Io = std.Io;

pub const View = struct {
    transforms: *const middleware.TransformPipeline,
    has_custom_transformers: bool,
};

pub const Configuration = struct {
    transforms: middleware.TransformPipeline = .{},
    has_custom_transformers: bool = false,
    mutex: Io.Mutex = .init,
    serving: bool = false,

    /// Creates the configuration with Telar's built-in provider transforms.
    ///
    /// ```zig
    /// var configuration = try Configuration.init();
    /// ```
    pub fn init() !Configuration {
        var configuration: Configuration = .{};
        try configuration.transforms.add(provider.claudeRequestTransformer());

        return configuration;
    }

    /// Adds one custom transform while configuration remains mutable.
    /// Concurrent traffic cannot observe a partially modified pipeline.
    ///
    /// ```zig
    /// try configuration.add(io, transformer);
    /// ```
    pub fn add(configuration: *Configuration, io: Io, transformer: middleware.Transformer) !void {
        configuration.mutex.lockUncancelable(io);
        defer configuration.mutex.unlock(io);
        if (configuration.serving) {
            return error.ProxyAlreadyRunning;
        }

        try configuration.transforms.add(transformer);
        configuration.has_custom_transformers = true;
    }

    /// Atomically freezes configuration for the lifetime of the serving loop.
    /// A second call rejects a duplicate listener worker.
    ///
    /// ```zig
    /// try configuration.beginServing(io);
    /// ```
    pub fn beginServing(configuration: *Configuration, io: Io) !void {
        configuration.mutex.lockUncancelable(io);
        defer configuration.mutex.unlock(io);
        if (configuration.serving) {
            return error.ProxyAlreadyRunning;
        }

        configuration.serving = true;
    }

    /// Borrows the immutable transform pipeline after service construction.
    /// The returned pointers remain valid while the configuration is alive.
    ///
    /// ```zig
    /// const view = configuration.view();
    /// ```
    pub fn view(configuration: *const Configuration) View {
        return .{
            .transforms = &configuration.transforms,
            .has_custom_transformers = configuration.has_custom_transformers,
        };
    }
};

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
