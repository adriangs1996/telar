const std = @import("std");
const Application = @import("Application.zig");
const lua_build = @import("lua.zig");
const freetype_build = @import("freetype.zig");
const assets_build = @import("assets.zig");
const client_build = @import("client.zig");

benchmarks: *std.Build.Step.Compile,
echo_probe: *std.Build.Step.Compile,

/// Register optimized benchmarks and probes: `Benchmarks.init(b, app)`.
pub fn init(b: *std.Build, app: Application) @This() {
    // Benchmarks use their own optimized module graph. Running a Debug core
    // under a ReleaseFast benchmark executable would measure safety checks and
    // make the result depend on whichever build command happened to run it.
    const bench_optimize: std.builtin.OptimizeMode = if (app.modules.optimize == .Debug)
        .ReleaseFast
    else
        app.modules.optimize;
    const bench_lua_api = lua_build.add(b, .{ .target = app.modules.target, .optimize = bench_optimize, .name = "lua-bench" });
    const bench_lua = b.createModule(.{
        .root_source_file = b.path("src/lua/lua.zig"),
        .target = app.modules.target,
        .optimize = bench_optimize,
    });
    bench_lua.addImport("lua-api", bench_lua_api);
    const bench_unicode = b.createModule(.{
        .root_source_file = b.path("src/core/unicode.zig"),
        .target = app.modules.target,
        .optimize = bench_optimize,
    });
    bench_unicode.addImport("ghostty-vt", app.modules.ghostty_vt);
    const bench_core = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = app.modules.target,
        .optimize = bench_optimize,
    });
    bench_core.addImport("unicode", bench_unicode);
    const bench_backend = b.createModule(.{
        .root_source_file = b.path("src/backend/backend.zig"),
        .target = app.modules.target,
        .optimize = bench_optimize,
        .link_libc = true,
    });
    bench_backend.addImport("telar-core", bench_core);
    bench_backend.addImport("ghostty-vt", app.modules.ghostty_vt);
    bench_backend.addImport("wuffs", app.modules.wuffs);
    bench_backend.addImport("tls", app.modules.tls);
    bench_backend.addImport("telar-lua", bench_lua);
    bench_backend.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ app.modules.nghttp2_prefix, "include" }) });
    bench_backend.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ app.modules.nghttp2_prefix, "lib" }) });
    bench_backend.linkSystemLibrary("nghttp2", .{});
    bench_backend.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ app.modules.brotli_prefix, "include" }) });
    bench_backend.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ app.modules.brotli_prefix, "lib" }) });
    bench_backend.linkSystemLibrary("brotlidec", .{});
    bench_backend.linkSystemLibrary("sqlite3", .{});
    const bench_kitty_protocol = b.createModule(.{
        .root_source_file = b.path("src/kitty_protocol/kitty_protocol.zig"),
        .target = app.modules.target,
        .optimize = bench_optimize,
    });
    const bench_client = client_build.add(b, bench_core, .{ .api = bench_lua_api, .telar = bench_lua });
    const bench_frontend = b.createModule(.{
        .root_source_file = b.path("src/frontend/frontend.zig"),
        .target = app.modules.target,
        .optimize = bench_optimize,
        .link_libc = true,
    });
    const bench_freetype = freetype_build.add(b, .{ .target = app.modules.target, .optimize = bench_optimize, .disable_coverage = false });
    bench_frontend.addImport("telar-core", bench_core);
    bench_frontend.addImport("telar-client", bench_client);
    bench_frontend.addImport("kitty_protocol", bench_kitty_protocol);
    bench_frontend.addImport("lua-api", bench_lua_api);
    bench_frontend.addImport("telar-lua", bench_lua);
    bench_frontend.addImport("freetype", bench_freetype);
    bench_frontend.addImport("assets", assets_build.add(b, app.modules.target, bench_optimize));

    const benchmarks = b.addExecutable(.{
        .name = "telar-benchmarks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/main.zig"),
            .target = app.modules.target,
            .optimize = bench_optimize,
            .link_libc = true,
        }),
    });
    benchmarks.root_module.addImport("telar-core", bench_core);
    benchmarks.root_module.addImport("telar-backend", bench_backend);
    benchmarks.root_module.addImport("telar-frontend", bench_frontend);
    benchmarks.root_module.addImport("telar-client", bench_client);

    const echo_probe = b.addExecutable(.{
        .name = "echo-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/echo_probe.zig"),
            .target = app.modules.target,
            .optimize = bench_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "ghostty-vt", .module = app.modules.ghostty_vt },
                .{ .name = "telar-backend", .module = bench_backend },
                .{ .name = "telar-frontend", .module = bench_frontend },
                .{ .name = "telar-core", .module = bench_core },
                .{ .name = "telar-client", .module = bench_client },
            },
        }),
    });
    b.step("echo-probe", "Build the echo VT oracle and minimal interposition controls").dependOn(&b.addInstallArtifact(echo_probe, .{}).step);
    benchmarks.root_module.addImport("ghostty-vt", app.modules.ghostty_vt);
    const run_benchmarks = b.addRunArtifact(benchmarks);
    if (b.args) |args| {
        run_benchmarks.addArgs(args);
    }
    b.step("bench", "Run the interactive path benchmarks").dependOn(&run_benchmarks.step);

    const verify_terminal_browser = b.addSystemCommand(&.{"python3"});
    verify_terminal_browser.addFileArg(b.path("tools/verify_terminal_browser.py"));
    if (b.args) |args| {
        verify_terminal_browser.addArgs(args);
    }
    b.step(
        "verify-terminal-browser",
        "Build and exercise pinned terminal-browser inside Telar on Ghostty",
    ).dependOn(&verify_terminal_browser.step);

    return .{ .benchmarks = benchmarks, .echo_probe = echo_probe };
}
