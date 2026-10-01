//! The modules one telar binary is built from for one target: the runtime,
//! the shared client, the model, the core values and what they import. The
//! shipped build and the cross check assemble the same graph, so a target
//! the check compiles is built the way it ships.
const std = @import("std");
const Coverage = @import("Coverage.zig");
const Libraries = @import("Libraries.zig");
const Modules = @import("Modules.zig");
const NativeLibrary = @import("NativeLibrary.zig");
const lua_build = @import("lua.zig");
const freetype_build = @import("freetype.zig");
const model_build = @import("model.zig");
const client_build = @import("client.zig");
const ModuleGraph = @This();

libraries: Libraries,
core: *std.Build.Module,
data: *std.Build.Module,
client: *std.Build.Module,
backend: *std.Build.Module,
lua_api: *std.Build.Module,
telar_lua: *std.Build.Module,
tls: *std.Build.Module,
freetype: *std.Build.Module,
ghostty_vt: *std.Build.Module,
wuffs: *std.Build.Module,
natives: []const NativeLibrary,
target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,

/// Assembles the graph for `target`, linking `natives` where the libraries
/// need C. Null while a lazy dependency is still being fetched.
///
/// ```zig
/// const graph = ModuleGraph.create(b, target, optimize, natives, coverage) orelse return null;
/// ```
pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, natives: []const NativeLibrary, coverage: Coverage) ?ModuleGraph {
    // Parsing PTY output is the hottest part of the interactive path. Keep the
    // application debuggable, but build the third-party emulator as optimized
    // code just as herdr does; a Debug libghostty-vt makes terminal latency
    // dominate before telar's own renderer even sees a frame.
    const vt_optimize: std.builtin.OptimizeMode = if (optimize == .Debug)
        .ReleaseFast
    else
        optimize;

    const ghostty_dep = b.dependency("ghostty_vt", .{
        .target = target,
        .optimize = vt_optimize,
    });
    const ghostty_vt = ghostty_dep.module("ghostty-vt");
    const wuffs_dep = ghostty_dep.builder.lazyDependency("wuffs", .{
        .target = target,
        .optimize = vt_optimize,
    }) orelse return null;
    const wuffs = wuffs_dep.module("wuffs");
    coverage.excludeCSourceCoverage(b, ghostty_vt);
    coverage.excludeCSourceCoverage(b, wuffs);

    const lua_api = lua_build.add(b, .{ .target = target, .optimize = optimize, .name = "lua" });
    coverage.instrumentModule(lua_api);
    const telar_lua = b.createModule(.{
        .root_source_file = b.path("src/lua/lua.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    telar_lua.addImport("lua-api", lua_api);
    coverage.instrumentModule(telar_lua);
    const tls = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    }).module("tls");

    // The width tables come from the emulator that renders the panes; the
    // drawing layer only names the `unicode` library, never its provider.
    const freetype = freetype_build.add(b, .{ .target = target, .optimize = optimize, .disable_coverage = coverage.enabled });
    const libraries = Libraries.create(b, target, optimize, &.{
        .{
            .name = "ghostty-vt",
            .module = ghostty_vt,
        },
        .{
            .name = "freetype",
            .module = freetype,
        },
        .{
            .name = "wuffs",
            .module = wuffs,
        },
        .{
            .name = "tls",
            .module = tls,
        },
    }, natives);
    for (libraries.modules) |library| {
        coverage.instrumentModule(library.?);
    }

    // Runtime and client share values through core; neither common package
    // imports an adapter.
    const core = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    libraries.addImports(core);
    libraries.addImports(telar_lua);
    coverage.instrumentModule(core);
    const data = model_build.create(b, core, libraries);
    coverage.instrumentModule(data);
    const client = client_build.add(
        b,
        .{
            .core = core,
            .data = data,
            .lua = .{
                .api = lua_api,
                .telar = telar_lua,
            },
            .libraries = libraries,
        },
    );
    coverage.instrumentModule(client);

    const backend = b.createModule(.{
        .root_source_file = b.path("src/backend/backend.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    backend.addImport("telar-core", core);
    backend.addImport("telar-lua", telar_lua);
    backend.addImport("lua-api", lua_api);
    backend.addImport("ghostty-vt", ghostty_vt);
    backend.addImport("tls", tls);
    libraries.addImports(backend);
    coverage.instrumentModule(backend);

    return .{
        .libraries = libraries,
        .core = core,
        .data = data,
        .client = client,
        .backend = backend,
        .lua_api = lua_api,
        .telar_lua = telar_lua,
        .tls = tls,
        .freetype = freetype,
        .ghostty_vt = ghostty_vt,
        .wuffs = wuffs,
        .natives = natives,
        .target = target,
        .optimize = optimize,
    };
}

/// The graph with what one build adds to it: embedded assets, its options
/// and whether it carries the native client.
///
/// ```zig
/// const modules = graph.modules(assets, exe_options, native_client);
/// ```
pub fn modules(self: ModuleGraph, assets: *std.Build.Module, build_options: *std.Build.Step.Options, native_client: bool) Modules {
    return .{
        .libraries = self.libraries,
        .data = self.data,
        .core = self.core,
        .backend = self.backend,
        .client = self.client,
        .lua_api = self.lua_api,
        .telar_lua = self.telar_lua,
        .tls = self.tls,
        .freetype = self.freetype,
        .assets = assets,
        .gui = null,
        .ghostty_vt = self.ghostty_vt,
        .wuffs = self.wuffs,
        .natives = self.natives,
        .native_client = native_client,
        .target = self.target,
        .optimize = self.optimize,
        .build_options = build_options,
    };
}
