const SuiteModules = @This();
const std = @import("std");
const Suite = @import("Suite.zig");
unicode: *std.Build.Module,
core: *std.Build.Module,
backend: *std.Build.Module,
frontend: *std.Build.Module,
client: *std.Build.Module,
kitty_protocol: *std.Build.Module,
lua_api: *std.Build.Module,
telar_lua: *std.Build.Module,
tls: *std.Build.Module,
freetype: *std.Build.Module,
ghostty_vt: *std.Build.Module,
wuffs: *std.Build.Module,
nghttp2_prefix: []const u8,
brotli_prefix: []const u8,
target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,

pub fn addSuiteTest(modules: SuiteModules, b: *std.Build, suite: Suite) *std.Build.Step.Compile {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(suite.path),
            .target = modules.target,
            .optimize = modules.optimize,
            .link_libc = suite.libc,
        }),
    });

    tests.root_module.addImport("unicode", modules.unicode);
    tests.root_module.addImport("telar-core", modules.core);
    tests.root_module.addImport("telar-backend", modules.backend);
    tests.root_module.addImport("telar-frontend", modules.frontend);
    tests.root_module.addImport("telar-client", modules.client);
    tests.root_module.addImport("kitty_protocol", modules.kitty_protocol);
    tests.root_module.addImport("lua-api", modules.lua_api);
    tests.root_module.addImport("telar-lua", modules.telar_lua);
    tests.root_module.addImport("tls", modules.tls);
    tests.root_module.addImport("freetype", modules.freetype);
    tests.root_module.addImport("wuffs", modules.wuffs);
    tests.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ modules.nghttp2_prefix, "include" }) });
    tests.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ modules.nghttp2_prefix, "lib" }) });
    tests.root_module.linkSystemLibrary("nghttp2", .{});
    tests.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ modules.brotli_prefix, "include" }) });
    tests.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ modules.brotli_prefix, "lib" }) });
    tests.root_module.linkSystemLibrary("brotlidec", .{});

    if (suite.vt) {
        tests.root_module.addImport("ghostty-vt", modules.ghostty_vt);
    }

    return tests;
}
