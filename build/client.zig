const std = @import("std");
const ClientModules = @import("ClientModules.zig");

// Configuration and plugins are shared client behavior, so the common client
// owns the Lua modules; adapters never load configuration themselves.
pub fn add(b: *std.Build, modules: ClientModules) *std.Build.Module {
    const client = b.createModule(.{
        .root_source_file = b.path("src/client/client.zig"),
        .target = modules.core.resolved_target,
        .optimize = modules.core.optimize,
        .link_libc = true,
    });

    client.addImport("telar-core", modules.core);
    client.addImport("model", modules.data);
    client.addImport("telar-lua", modules.lua.telar);
    client.addImport("lua-api", modules.lua.api);
    return client;
}
