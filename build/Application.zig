const std = @import("std");
const Coverage = @import("Coverage.zig");
const Modules = @import("Modules.zig");
const lua_build = @import("lua.zig");
const freetype_build = @import("freetype.zig");
const assets_build = @import("assets.zig");
const client_build = @import("client.zig");
const c_flags = @import("c_flags.zig");

modules: Modules,
coverage: Coverage,
exe: *std.Build.Step.Compile,
install: *std.Build.Step.InstallArtifact,

/// Assemble the shipped module graph and run/install steps: `Application.init(b)`.
pub fn init(b: *std.Build) ?@This() {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const coverage = Coverage.init(b);

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
    const telar_lua = b.addModule("telar-lua", .{
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
    const nghttp2_prefix = b.option(
        []const u8,
        "nghttp2",
        "Prefix of a libnghttp2 installation",
    ) orelse if (target.result.os.tag == .macos)
        if (target.result.cpu.arch == .aarch64)
            "/opt/homebrew/opt/libnghttp2"
        else
            "/usr/local/opt/libnghttp2"
    else
        "/usr";
    const brotli_prefix = b.option(
        []const u8,
        "brotli",
        "Prefix of a libbrotli installation",
    ) orelse if (target.result.os.tag == .macos)
        if (target.result.cpu.arch == .aarch64)
            "/opt/homebrew/opt/brotli"
        else
            "/usr/local/opt/brotli"
    else
        "/usr";

    // The width tables, behind a module name so the drawing layer never names
    // its provider. Everything that draws imports `unicode`; only this line
    // decides which implementation answers, which is what keeps the drawing
    // core liftable into a build with no emulator in it.
    const unicode = b.createModule(.{
        .root_source_file = b.path("src/core/unicode.zig"),
        .target = target,
        .optimize = optimize,
    });
    unicode.addImport("ghostty-vt", ghostty_vt);
    coverage.instrumentModule(unicode);

    const kitty_protocol = b.addModule("kitty_protocol", .{
        .root_source_file = b.path("src/kitty_protocol/kitty_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    coverage.instrumentModule(kitty_protocol);

    // Runtime and client share values through core. The TUI additionally
    // imports client behavior; neither common package imports an adapter.
    const core = b.addModule("telar-core", .{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    core.addImport("unicode", unicode);
    coverage.instrumentModule(core);
    const client = client_build.add(b, core, .{ .api = lua_api, .telar = telar_lua });
    coverage.instrumentModule(client);

    const backend = b.addModule("telar-backend", .{
        .root_source_file = b.path("src/backend/backend.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    backend.addImport("telar-core", core);
    backend.addImport("telar-lua", telar_lua);
    backend.addImport("lua-api", lua_api);
    backend.addImport("ghostty-vt", ghostty_vt);
    backend.addImport("wuffs", wuffs);
    backend.addImport("tls", tls);
    backend.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ nghttp2_prefix, "include" }) });
    backend.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ nghttp2_prefix, "lib" }) });
    backend.linkSystemLibrary("nghttp2", .{});
    backend.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ brotli_prefix, "include" }) });
    backend.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ brotli_prefix, "lib" }) });
    backend.linkSystemLibrary("brotlidec", .{});
    backend.linkSystemLibrary("sqlite3", .{});
    coverage.instrumentModule(backend);

    const frontend = b.addModule("telar-frontend", .{
        .root_source_file = b.path("src/frontend/frontend.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const freetype = freetype_build.add(b, .{ .target = target, .optimize = optimize, .disable_coverage = coverage.enabled });
    frontend.addImport("telar-core", core);
    frontend.addImport("telar-client", client);
    frontend.addImport("kitty_protocol", kitty_protocol);
    frontend.addImport("telar-lua", telar_lua);
    frontend.addImport("lua-api", lua_api);
    frontend.addImport("freetype", freetype);
    const assets = assets_build.add(b, target, optimize);
    frontend.addImport("assets", assets);
    if (target.result.os.tag == .macos) {
        frontend.addCSourceFile(.{
            .file = b.path("src/frontend/attachments/darwin.m"),
            .flags = c_flags.forCoverage(b, &.{"-fobjc-arc"}, coverage.enabled),
        });
        frontend.linkFramework("AppKit", .{});
        frontend.linkFramework("ImageIO", .{});
        frontend.linkFramework("CoreGraphics", .{});
    } else if (target.result.os.tag == .windows) {
        frontend.linkSystemLibrary("user32", .{});
    }
    // One shipped binary contains both the client and runtime entry points.
    const exe = b.addExecutable(.{
        .name = "telar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("telar-backend", backend);
    exe.root_module.addImport("telar-frontend", frontend);
    exe.root_module.addImport("telar-client", client);
    exe.root_module.addImport("telar-core", core);
    exe.root_module.addImport("ghostty-vt", ghostty_vt);
    const diagnostics_enabled = b.option(
        bool,
        "diagnostics",
        "Collect development telemetry in optimized builds",
    ) orelse false;
    const exe_options = b.addOptions();
    exe_options.addOption(bool, "diagnostics", diagnostics_enabled);
    exe_options.addOption(bool, "echo_trace", b.option(bool, "echo-trace", "Record bounded echo phase timestamps until shutdown") orelse false);
    exe_options.addOption(bool, "echo_trace_cpu", b.option(bool, "echo-trace-cpu", "Include thread CPU clocks in diagnostic echo traces") orelse false);
    exe.root_module.addOptions("build_options", exe_options);
    // `zig build` installs only the shipped binary. Examples and probes get
    // their own steps so the default build and `run` never wait on them.
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const run_exe = b.addRunArtifact(exe);
    // Build-runner color overrides leak into panes and can downgrade truecolor.
    run_exe.color = .manual;
    run_exe.step.dependOn(&install_exe.step);
    run_exe.setEnvironmentVariable(
        "TELAR_DEVELOPMENT_CONFIG",
        b.pathFromRoot("dev/config.lua"),
    );
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    b.step("run", "Run telar").dependOn(&run_exe.step);

    const modules: Modules = .{
        .unicode = unicode,
        .core = core,
        .backend = backend,
        .frontend = frontend,
        .client = client,
        .kitty_protocol = kitty_protocol,
        .lua_api = lua_api,
        .telar_lua = telar_lua,
        .tls = tls,
        .freetype = freetype,
        .assets = assets,
        .gui = null,
        .ghostty_vt = ghostty_vt,
        .wuffs = wuffs,
        .nghttp2_prefix = nghttp2_prefix,
        .brotli_prefix = brotli_prefix,
        .target = target,
        .optimize = optimize,
        .build_options = exe_options,
    };
    return .{ .modules = modules, .coverage = coverage, .exe = exe, .install = install_exe };
}
