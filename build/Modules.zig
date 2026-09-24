const std = @import("std");
const Suite = @import("Suite.zig");
const Libraries = @import("Libraries.zig");
const Modules = @This();

libraries: Libraries,
core: *std.Build.Module,
data: *std.Build.Module,
backend: *std.Build.Module,
frontend: *std.Build.Module,
client: *std.Build.Module,
kitty_protocol: *std.Build.Module,
lua_api: *std.Build.Module,
telar_lua: *std.Build.Module,
tls: *std.Build.Module,
freetype: *std.Build.Module,
assets: *std.Build.Module,
gui: ?*std.Build.Module = null,
syntax_library: ?std.Build.LazyPath = null,
ghostty_vt: *std.Build.Module,
wuffs: *std.Build.Module,
nghttp2_prefix: []const u8,
brotli_prefix: []const u8,
target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
build_options: *std.Build.Step.Options,

pub fn addSuiteTest(self: Modules, b: *std.Build, suite: Suite) *std.Build.Step.Compile {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(suite.path),
            .target = self.target,
            .optimize = self.optimize,
            .link_libc = suite.libc,
        }),
    });

    if (std.mem.eql(u8, suite.path, "src/main.zig")) {
        tests.root_module.addOptions("build_options", self.build_options);
    }

    tests.root_module.addImport("telar-core", self.core);
    tests.root_module.addImport("telar-backend", self.backend);
    tests.root_module.addImport("telar-frontend", self.frontend);
    tests.root_module.addImport("telar-client", self.client);
    tests.root_module.addImport("model", self.data);
    tests.root_module.addImport("kitty_protocol", self.kitty_protocol);
    tests.root_module.addImport("lua-api", self.lua_api);
    tests.root_module.addImport("telar-lua", self.telar_lua);
    tests.root_module.addImport("tls", self.tls);
    tests.root_module.addImport("freetype", self.freetype);
    tests.root_module.addImport("assets", self.assets);
    if (self.gui) |gui| {
        tests.root_module.addImport("telar-gui", gui);
    }
    tests.root_module.addImport("wuffs", self.wuffs);
    self.libraries.addImports(tests.root_module);
    tests.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ self.nghttp2_prefix, "include" }) });
    tests.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ self.nghttp2_prefix, "lib" }) });
    tests.root_module.linkSystemLibrary("nghttp2", .{});
    tests.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ self.brotli_prefix, "include" }) });
    tests.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ self.brotli_prefix, "lib" }) });
    tests.root_module.linkSystemLibrary("brotlidec", .{});

    if (suite.vt) {
        tests.root_module.addImport("ghostty-vt", self.ghostty_vt);
    }

    return tests;
}
