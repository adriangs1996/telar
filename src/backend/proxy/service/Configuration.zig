const TransformPipeline = @import("../TransformPipeline.zig");
const std = @import("std");
const claude_transport = @import("../provider/claude_transport.zig");
const Transformer = @import("../Transformer.zig");
const Configuration = @This();

transforms: TransformPipeline = .{},
has_custom_transformers: bool = false,
mutex: std.Io.Mutex = .init,
serving: bool = false,

/// Creates the configuration with Telar's built-in provider transforms.
///
/// ```zig
/// var configuration = try Configuration.init();
/// ```
pub fn init() !Configuration {
    var configuration: Configuration = .{};
    try configuration.transforms.add(claude_transport.requestTransformer());

    return configuration;
}

/// Adds one custom transform while configuration remains mutable.
/// Concurrent traffic cannot observe a partially modified pipeline.
///
/// ```zig
/// try configuration.add(io, transformer);
/// ```
pub fn add(self: *Configuration, io: std.Io, transformer: Transformer) !void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (self.serving) {
        return error.ProxyAlreadyRunning;
    }

    try self.transforms.add(transformer);
    self.has_custom_transformers = true;
}

/// Atomically freezes configuration for the lifetime of the serving loop.
/// A second call rejects a duplicate listener worker.
///
/// ```zig
/// try configuration.beginServing(io);
/// ```
pub fn beginServing(self: *Configuration, io: std.Io) !void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (self.serving) {
        return error.ProxyAlreadyRunning;
    }

    self.serving = true;
}

/// Borrows the immutable transform pipeline after service construction.
/// The returned pointers remain valid while the configuration is alive.
///
/// ```zig
/// const view = configuration.view();
/// ```
pub fn view(self: *const Configuration) View {
    return .{
        .transforms = &self.transforms,
        .has_custom_transformers = self.has_custom_transformers,
    };
}

const View = struct {
    transforms: *const TransformPipeline,
    has_custom_transformers: bool,
};
