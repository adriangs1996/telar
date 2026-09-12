const std = @import("std");
const LuaConfig = @import("LuaConfig.zig");

pub fn add(b: *std.Build, config: LuaConfig) *std.Build.Module {
    const target = config.target;
    const source_root = b.path("vendor/lua-5.5.1/src");
    const lua = b.addLibrary(.{
        .name = config.name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = config.optimize,
            .link_libc = true,
        }),
    });
    lua.root_module.addIncludePath(source_root);
    lua.root_module.addCSourceFiles(.{
        .root = source_root,
        .files = &.{
            "lapi.c",
            "lauxlib.c",
            "lbaselib.c",
            "lcode.c",
            "lcorolib.c",
            "lctype.c",
            "ldebug.c",
            "ldo.c",
            "ldump.c",
            "lfunc.c",
            "lgc.c",
            "llex.c",
            "lmathlib.c",
            "lmem.c",
            "lobject.c",
            "lopcodes.c",
            "lparser.c",
            "lstate.c",
            "lstring.c",
            "lstrlib.c",
            "ltable.c",
            "ltablib.c",
            "ltm.c",
            "lundump.c",
            "lutf8lib.c",
            "lvm.c",
            "lzio.c",
        },
        .flags = if (target.result.os.tag == .windows)
            &.{"-std=c99"}
        else
            &.{ "-std=c99", "-DLUA_USE_POSIX" },
    });
    if (target.result.os.tag != .windows) {
        lua.root_module.linkSystemLibrary("m", .{});
    }

    const api = b.createModule(.{
        .root_source_file = b.path("src/lua/lua_api.zig"),
        .target = target,
        .optimize = config.optimize,
        .link_libc = true,
    });
    api.addIncludePath(source_root);
    api.linkLibrary(lua);
    return api;
}
