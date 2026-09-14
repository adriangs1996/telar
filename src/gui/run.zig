//! Adopts the CLI-prepared runtime connection and native client configuration.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Application = @import("Application.zig");
const WindowIdentity = @import("WindowIdentity.zig");

/// Opens a native terminal session. Example: `const status = try run(init, connection, options);`
pub fn run(init: std.process.Init, connection: *core.SocketChannel, options: client.Options) !u8 {
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
    var app = try Application.init(.{
        .gpa = init.gpa,
        .io = init.io,
        .connection = connection,
        .host_size = .{ .cols = 80, .rows = 24 },
        .client_identity = identity.value,
        .options = options,
    });
    adopted = true;
    defer app.deinit();
    app.home = init.environ.getPosix("HOME") orelse "";
    return app.run("Telar");
}
