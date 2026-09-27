//! Adopts the CLI-prepared runtime connection and native client configuration.
const localsocket = @import("localsocket");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const GuiAdapter = @import("GuiAdapter.zig");
const WindowIdentity = @import("WindowIdentity.zig");

/// Opens a native terminal session. Without a connection, the window
/// connects to `options.machine` itself once it is on screen.
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

    // A window on another machine is its own client there: its identity and
    // its forwarded socket carry both the window slot and the machine.
    var window_options = options;
    var client_identity = identity.value;
    if (window_options.machine) |*machine| {
        switch (machine.*) {
            .remote => |*remote_machine| {
                remote_machine.window_slot = identity.slot;
                client_identity = machineIdentity(identity.value, remote_machine.destination);
            },
            .local => {},
        }
    }

    const app = try GuiAdapter.init(.{
        .gpa = init.gpa,
        .io = init.io,
        .connection = connection,
        .host_size = .{ .cols = 80, .rows = 24 },
        .client_identity = client_identity,
        .options = window_options,
    });

    adopted = true;
    defer app.deinit();
    return app.run("Telar");
}

fn machineIdentity(window: core.ClientIdentity, destination: []const u8) core.ClientIdentity {
    const value = std.hash.Wyhash.hash(@intFromEnum(window), destination);
    return @enumFromInt(if (value == 0) 1 else value);
}

test "one window slot gets a distinct identity on each machine" {
    const window: core.ClientIdentity = @enumFromInt(42);

    try std.testing.expect(machineIdentity(window, "dev@box") != machineIdentity(window, "dev@gpu"));
    try std.testing.expectEqual(machineIdentity(window, "dev@box"), machineIdentity(window, "dev@box"));
    try std.testing.expect(machineIdentity(window, "dev@box") != window);
}
