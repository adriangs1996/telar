const std = @import("std");
const Libraries = @import("Libraries.zig");
const NativeLibrary = @import("NativeLibrary.zig");

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
ghostty_vt: *std.Build.Module,
wuffs: *std.Build.Module,
natives: []const NativeLibrary,
/// Whether this graph builds the native client and its helpers.
native_client: bool,
target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
build_options: *std.Build.Step.Options,

/// Embeds `install.sh` as `@embedFile("install.sh")` in a module that runs
/// `telar machine setup`, which sends it to the machine it sets up.
///
/// ```zig
/// Modules.addInstaller(b, exe.root_module);
/// ```
pub fn addInstaller(b: *std.Build, module: *std.Build.Module) void {
    module.addAnonymousImport("install.sh", .{ .root_source_file = b.path("install.sh") });
}
