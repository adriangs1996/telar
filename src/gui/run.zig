//! Adopts the CLI-prepared runtime connection and native client configuration.
const localsocket = @import("localsocket");
const std = @import("std");
const client = @import("telar-client");
const GuiAdapter = @import("GuiAdapter.zig");
const WindowIdentity = @import("WindowIdentity.zig");

/// Opens a native terminal session. Without a connection, the window
/// connects to `options.machine` itself once it is on screen, and opens the
/// saved machines and `options.open_machine` beside it.
/// Example: `const status = try run(init, null, options);`
pub fn run(init: std.process.Init, connection: ?*localsocket.SocketChannel, options: client.Options) !u8 {
    var adopted = false;
    errdefer if (!adopted) {
        if (options.lua_generation) |generation| {
            generation.deinit();
        }

        if (options.plugin_registry) |registry| {
            init.gpa.destroy(registry);
        }

        if (options.trust_store) |store| {
            init.gpa.destroy(store);
        }
    };
    var identity = try WindowIdentity.acquire(init.io, options.endpoint);
    defer identity.deinit(init.io);

    const app = try GuiAdapter.init(.{
        .gpa = init.gpa,
        .io = init.io,
        .connection = connection,
        .host_size = .{ .cols = 80, .rows = 24 },
        .client_identity = identity.value,
        .options = options,
    });

    adopted = true;
    defer app.deinit();
    return app.run("Telar");
}
