//! Public namespace for one long-lived Telar runtime.

const config = @import("config.zig");
const client_session = @import("client/root.zig").session;
const instance = @import("instance.zig");
const observability = @import("observability/root.zig");

pub const GraphicsLimits = config.GraphicsLimits;
pub const Dependencies = config.Dependencies;
pub const Initialization = config.Initialization;
pub const Options = config.Options;
pub const Runtime = instance.Runtime;
pub const ServeOptions = Options;
pub const AgentDescriptionOptions = config.AgentDescriptionOptions;
pub const ProxyOptions = config.ProxyOptions;
pub const ClientKey = client_session.Key;
pub const IngestTestGate = config.IngestTestGate;
pub const LaunchTestFault = config.LaunchTestFault;
pub const system_metrics = observability.system_metrics;
/// Freezing of one generation into a runtime-owned shared object, exposed so
/// the benchmarks measure the same copy the send loop performs.
pub const freezeSharedPixels = @import("attachment/graphics.zig").freezeSharedPixels;
pub const serve = instance.serve;

test "Runtime owns its endpoint until the injected stop dependency fires" {
    const std = @import("std");
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(
        &endpoint_buffer,
        "{s}/runtime-contract.sock",
        .{directory_buffer[0..directory_len]},
    );
    var stop_storage: [1]u8 = undefined;
    var stop: std.Io.Queue(u8) = .init(&stop_storage);
    var runtime: Runtime = undefined;
    try runtime.init(.{
        .dependencies = .{ .io = io, .allocator = std.testing.allocator },
        .options = .{
            .endpoint = endpoint,
            .environment = std.testing.environ,
            .stop = &stop,
        },
    });
    defer runtime.deinit();

    try stop.putOneUncancelable(io, 0);
    try runtime.run();
    runtime.deinit();

    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, endpoint, .{ .follow_symlinks = false }),
    );
}

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tests/root.zig");
}
