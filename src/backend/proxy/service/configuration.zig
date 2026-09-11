const Configuration = @This();
const middleware = @import("../middleware.zig");
const source_namespace = @import("configuration_support.zig");
const provider = @import("../provider/root.zig");
const View = @import("View.zig");
transforms: middleware.TransformPipeline = .{},
has_custom_transformers: bool = false,
mutex: source_namespace.Io.Mutex = .init,
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
pub fn add(configuration: *Configuration, io: source_namespace.Io, transformer: middleware.Transformer) !void {
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
pub fn beginServing(configuration: *Configuration, io: source_namespace.Io) !void {
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
