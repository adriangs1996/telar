const std = @import("std");
const Suite = @import("Suite.zig");
const Libraries = @import("Libraries.zig");
const NativeLibrary = @import("NativeLibrary.zig");
const Modules = @This();

libraries: Libraries,
core: *std.Build.Module,
data: *std.Build.Module,
backend: *std.Build.Module,
client: *std.Build.Module,
lua_api: *std.Build.Module,
telar_lua: *std.Build.Module,
tls: *std.Build.Module,
freetype: *std.Build.Module,
assets: *std.Build.Module,
gui: ?*std.Build.Module = null,
headless: ?*std.Build.Module = null,
syntax_library: ?std.Build.LazyPath = null,
ghostty_vt: *std.Build.Module,
wuffs: *std.Build.Module,
natives: []const NativeLibrary,
/// Whether this graph builds the native client and its helpers.
native_client: bool,
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
        addInstaller(b, tests.root_module);
    }

    tests.root_module.addImport("telar-core", self.core);
    tests.root_module.addImport("telar-backend", self.backend);
    tests.root_module.addImport("telar-client", self.client);
    tests.root_module.addImport("model", self.data);
    tests.root_module.addImport("lua-api", self.lua_api);
    tests.root_module.addImport("telar-lua", self.telar_lua);
    tests.root_module.addImport("tls", self.tls);
    tests.root_module.addImport("freetype", self.freetype);
    tests.root_module.addImport("assets", self.assets);
    if (self.gui) |gui| {
        tests.root_module.addImport("telar-gui", gui);
    }
    self.libraries.addImports(tests.root_module);

    if (suite.vt) {
        tests.root_module.addImport("ghostty-vt", self.ghostty_vt);
    }

    return tests;
}

/// Embeds `install.sh` as `@embedFile("install.sh")` in a module that runs
/// `telar machine setup`, which sends it to the machine it sets up.
///
/// ```zig
/// Modules.addInstaller(b, exe.root_module);
/// ```
pub fn addInstaller(b: *std.Build, module: *std.Build.Module) void {
    module.addAnonymousImport("install.sh", .{ .root_source_file = b.path("install.sh") });
}
