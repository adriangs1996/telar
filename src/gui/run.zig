//! Client process adapter for the native window: the same `Options` the
//! terminal adapter receives, presented through `Application`.
const std = @import("std");
const SocketChannelType = @import("telar-core").SocketChannel;
const Options = @import("telar-client").Options;
const Application = @import("Application.zig");

/// Adopts the configuration generation, plugin registry and trust store that
/// `options` carries, opens the window and returns the exit status when it
/// closes. The runtime connection is established like the terminal client's
/// and is not consumed yet.
///
/// ```zig
/// const status = try run(process_init, &connection, options);
/// ```
pub fn run(init: std.process.Init, connection: *SocketChannelType, options: Options) !u8 {
    _ = connection;
    defer {
        if (options.lua_generation) |generation| {
            generation.deinit();
        }
        if (options.plugin_registry) |registry| {
            init.gpa.destroy(registry);
        }
        if (options.trust_store) |store| {
            init.gpa.destroy(store);
        }
    }

    var app = Application.init(init.gpa, options);
    defer app.deinit();

    try app.run("Telar");
    return 0;
}
