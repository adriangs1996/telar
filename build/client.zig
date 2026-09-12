const std = @import("std");
const LuaModules = @import("LuaModules.zig");

// Configuration and plugins are shared client behavior, so the common client
// owns the Lua modules; adapters never load configuration themselves.
pub fn add(b: *std.Build, core: *std.Build.Module, lua: LuaModules) *std.Build.Module {
    const client = b.createModule(.{
        .root_source_file = b.path("src/client/client.zig"),
        .target = core.resolved_target,
        .optimize = core.optimize,
        .link_libc = true,
    });

    client.addImport("telar-core", core);
    client.addImport("telar-lua", lua.telar);
    client.addImport("lua-api", lua.api);
    return client;
}
