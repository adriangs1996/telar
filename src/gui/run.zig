//! Adopts the CLI-prepared runtime connection and native client configuration.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Application = @import("Application.zig");

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
    var identity: u64 = undefined;
    try init.io.randomSecure(std.mem.asBytes(&identity));
    var app = try Application.init(.{
        .gpa = init.gpa,
        .io = init.io,
        .connection = connection,
        .host_size = .{ .cols = 80, .rows = 24 },
        .client_identity = @enumFromInt(identity | 1),
        .options = options,
    });
    adopted = true;
    defer app.deinit();
    return app.run("Telar");
}
