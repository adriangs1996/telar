const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Parsing PTY output is the hottest part of the interactive path. Keep the
    // application debuggable, but build the third-party emulator as optimized
    // code just as herdr does; a Debug libghostty-vt makes terminal latency
    // dominate before telar's own renderer even sees a frame.
    const vt_optimize: std.builtin.OptimizeMode = if (optimize == .Debug)
        .ReleaseFast
    else
        optimize;

    const ghostty_vt = b.dependency("ghostty_vt", .{
        .target = target,
        .optimize = vt_optimize,
    }).module("ghostty-vt");

    const lua_api = addLua(b, target, optimize, "lua");
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

    // These module edges are the process boundary in code before IPC exists.
    // Both sides may import core. They cannot import each other.
    const core = b.addModule("telar-core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core.addImport("unicode", unicode);

    const backend = b.addModule("telar-backend", .{
        .root_source_file = b.path("src/backend/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    backend.addImport("telar-core", core);
    backend.addImport("ghostty-vt", ghostty_vt);
    backend.addImport("tls", tls);
    backend.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ nghttp2_prefix, "include" }) });
    backend.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ nghttp2_prefix, "lib" }) });
    backend.linkSystemLibrary("nghttp2", .{});
    backend.linkSystemLibrary("sqlite3", .{});

    const frontend = b.addModule("telar-frontend", .{
        .root_source_file = b.path("src/frontend/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const freetype = addFreeType(b, target, optimize);
    frontend.addImport("telar-core", core);
    frontend.addImport("lua-api", lua_api);
    frontend.addImport("freetype", freetype);
    if (target.result.os.tag == .macos) {
        frontend.addCSourceFile(.{
            .file = b.path("src/frontend/attachments/darwin.m"),
            .flags = &.{"-fobjc-arc"},
        });
        frontend.linkFramework("AppKit", .{});
        frontend.linkFramework("ImageIO", .{});
        frontend.linkFramework("CoreGraphics", .{});
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
    exe.root_module.addImport("telar-core", core);
    exe.root_module.addImport("ghostty-vt", ghostty_vt);
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    run_exe.setEnvironmentVariable(
        "TELAR_DEVELOPMENT_CONFIG",
        b.pathFromRoot("dev/config.lua"),
    );
    if (b.args) |args| run_exe.addArgs(args);
    b.step("run", "Run telar").dependOn(&run_exe.step);

    // Benchmarks use their own optimized module graph. Running a Debug core
    // under a ReleaseFast benchmark executable would measure safety checks and
    // make the result depend on whichever build command happened to run it.
    const bench_optimize: std.builtin.OptimizeMode = if (optimize == .Debug)
        .ReleaseFast
    else
        optimize;
    const bench_lua_api = addLua(b, target, bench_optimize, "lua-bench");
    const bench_unicode = b.createModule(.{
        .root_source_file = b.path("src/core/unicode.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_unicode.addImport("ghostty-vt", ghostty_vt);
    const bench_core = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_core.addImport("unicode", bench_unicode);
    const bench_backend = b.createModule(.{
        .root_source_file = b.path("src/backend/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .link_libc = true,
    });
    bench_backend.addImport("telar-core", bench_core);
    bench_backend.addImport("ghostty-vt", ghostty_vt);
    bench_backend.addImport("tls", tls);
    bench_backend.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ nghttp2_prefix, "include" }) });
    bench_backend.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ nghttp2_prefix, "lib" }) });
    bench_backend.linkSystemLibrary("nghttp2", .{});
    bench_backend.linkSystemLibrary("sqlite3", .{});
    const bench_frontend = b.createModule(.{
        .root_source_file = b.path("src/frontend/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .link_libc = true,
    });
    const bench_freetype = addFreeType(b, target, bench_optimize);
    bench_frontend.addImport("telar-core", bench_core);
    bench_frontend.addImport("lua-api", bench_lua_api);
    bench_frontend.addImport("freetype", bench_freetype);

    const benchmarks = b.addExecutable(.{
        .name = "telar-benchmarks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/main.zig"),
            .target = target,
            .optimize = bench_optimize,
            .link_libc = true,
        }),
    });
    benchmarks.root_module.addImport("telar-core", bench_core);
    benchmarks.root_module.addImport("telar-backend", bench_backend);
    benchmarks.root_module.addImport("telar-frontend", bench_frontend);
    benchmarks.root_module.addImport("ghostty-vt", ghostty_vt);
    const run_benchmarks = b.addRunArtifact(benchmarks);
    if (b.args) |args| run_benchmarks.addArgs(args);
    b.step("bench", "Run the interactive path benchmarks").dependOn(&run_benchmarks.step);

    const verify_terminal_browser = b.addSystemCommand(&.{"python3"});
    verify_terminal_browser.addFileArg(b.path("tools/verify_terminal_browser.py"));
    if (b.args) |args| verify_terminal_browser.addArgs(args);
    b.step(
        "verify-terminal-browser",
        "Build and exercise pinned terminal-browser inside Telar on Ghostty",
    ).dependOn(&verify_terminal_browser.step);

    // ---------------------------------------------------------------------
    // The example
    // ---------------------------------------------------------------------

    const sidebar = b.addExecutable(.{
        .name = "sidebar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/sidebar.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    sidebar.root_module.addImport("telar-frontend", frontend);
    b.installArtifact(sidebar);

    const run_sidebar = b.addRunArtifact(sidebar);
    run_sidebar.step.dependOn(b.getInstallStep());
    b.step("sidebar", "Run the example").dependOn(&run_sidebar.step);

    const terminal_browser_pane = b.addExecutable(.{
        .name = "terminal-browser-pane",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/terminal_browser_pane.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    terminal_browser_pane.root_module.addImport("telar-core", core);
    terminal_browser_pane.root_module.addImport("telar-backend", backend);
    terminal_browser_pane.root_module.addImport("telar-frontend", frontend);
    terminal_browser_pane.root_module.addImport("ghostty-vt", ghostty_vt);
    b.installArtifact(terminal_browser_pane);

    const run_terminal_browser_pane = b.addRunArtifact(terminal_browser_pane);
    run_terminal_browser_pane.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_terminal_browser_pane.addArgs(args);
    b.step(
        "terminal-browser-pane",
        "Run terminal-browser inside a centered half-size pane",
    ).dependOn(&run_terminal_browser_pane.step);

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    const test_step = b.step("test", "Run the tests");
    const transport_test_step = b.step("test-transport", "Run the local transport tests");
    const schema_test_step = b.step("test-schema", "Run the shared protocol schema tests");
    const frontend_test_step = b.step("test-frontend", "Run the frontend package tests");
    const release_step = b.step(
        "verify-release",
        "Run correctness, portability, and p99 performance gates",
    );
    const release_benchmarks = b.addRunArtifact(benchmarks);
    release_benchmarks.addArgs(&.{ "--samples", "8", "--sample-ms", "20", "--enforce" });
    release_step.dependOn(test_step);
    release_step.dependOn(&release_benchmarks.step);
    release_step.dependOn(b.getInstallStep());

    const Suite = struct {
        path: []const u8,
        vt: bool = false,
        libc: bool = false,
        transport: bool = false,
        schema: bool = false,
        frontend: bool = false,
    };
    const suites = [_]Suite{
        .{ .path = "src/core/ui/root.zig" },
        .{ .path = "src/core/select.zig" },
        // Only referenced through non-pub imports elsewhere, so their tests
        // never run unless they are their own suite roots.
        .{ .path = "src/core/graphics.zig" },
        .{ .path = "src/core/schema/wire.zig", .schema = true },
        .{ .path = "src/core/transport/root.zig", .transport = true },
        .{ .path = "src/core/diagnostics.zig" },
        .{ .path = "src/core/schema/handshake.zig", .schema = true },
        .{ .path = "src/core/schema_contract_test.zig", .schema = true },
        .{ .path = "src/core/plugin.zig" },
        .{ .path = "src/frontend/ui/root.zig" },
        // Capability roots can import sibling capabilities, so the package
        // root collects their tests without narrowing Zig's module path.
        .{ .path = "src/frontend/root.zig", .libc = true, .frontend = true },
        .{ .path = "src/frontend/transport/local.zig", .libc = true, .transport = true },
        .{ .path = "src/backend/history/escape.zig" },
        .{ .path = "src/backend/history/agent_detection.zig" },
        .{ .path = "src/backend/runtime/system_metrics.zig" },
        .{ .path = "src/frontend/widgets/workspace_model.zig" },
        .{ .path = "src/backend/proxy/root.zig", .libc = true },
        .{ .path = "src/backend/pane/blit.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/pane/damage.zig" },
        .{ .path = "src/backend/history/root.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/pty/root.zig", .libc = true },
        .{ .path = "src/backend/root.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/transport/local.zig", .libc = true, .transport = true },
        .{
            .path = "src/transport_integration_test.zig",
            .vt = true,
            .libc = true,
            .transport = true,
            .schema = true,
        },
        .{ .path = "src/main.zig", .vt = true, .libc = true },
        .{ .path = "examples/sidebar.zig", .vt = true, .libc = true },
        .{ .path = "examples/terminal_browser_pane.zig", .vt = true, .libc = true },
    };
    for (suites) |suite| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(suite.path),
                .target = target,
                .optimize = optimize,
                .link_libc = suite.libc,
            }),
        });
        tests.root_module.addImport("unicode", unicode);
        tests.root_module.addImport("telar-core", core);
        tests.root_module.addImport("telar-backend", backend);
        tests.root_module.addImport("telar-frontend", frontend);
        tests.root_module.addImport("lua-api", lua_api);
        tests.root_module.addImport("tls", tls);
        tests.root_module.addImport("freetype", freetype);
        tests.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ nghttp2_prefix, "include" }) });
        tests.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ nghttp2_prefix, "lib" }) });
        tests.root_module.linkSystemLibrary("nghttp2", .{});
        if (suite.vt) tests.root_module.addImport("ghostty-vt", ghostty_vt);
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
        if (suite.transport) transport_test_step.dependOn(&run_tests.step);
        if (suite.schema) schema_test_step.dependOn(&run_tests.step);
        if (suite.frontend) frontend_test_step.dependOn(&run_tests.step);
    }

    // The same drawing code against a width table that answers nonsense, so
    // the module seam is proven rather than asserted. Only this file's tests
    // run: the ones inside `ui/root.zig` assert real widths and cannot pass here.
    const unicode_fake = b.createModule(.{
        .root_source_file = b.path("src/core/unicode_fake.zig"),
        .target = target,
        .optimize = optimize,
    });
    const substitution = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/unicode_substitution_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"injected table"},
    });
    substitution.root_module.addImport("unicode", unicode_fake);
    test_step.dependOn(&b.addRunArtifact(substitution).step);

    // ---------------------------------------------------------------------
    // The proxy example
    // ---------------------------------------------------------------------

    // Deliberately outside the default build and outside `test`. It needs
    // sqlite3 and libnghttp2 from the system, and telar's whole point is that
    // the core builds anywhere with nothing but a Zig compiler. Someone who
    // wants the proxy asks for it.
    const proxyModule = struct {
        fn make(
            bb: *std.Build,
            path: []const u8,
            t: std.Build.ResolvedTarget,
            o: std.builtin.OptimizeMode,
            tls_mod: *std.Build.Module,
            vt_mod: *std.Build.Module,
            prefix: []const u8,
        ) *std.Build.Module {
            const mod = bb.createModule(.{
                .root_source_file = bb.path(path),
                .target = t,
                .optimize = o,
                .link_libc = true,
            });
            mod.addImport("tls", tls_mod);
            mod.addImport("ghostty-vt", vt_mod);
            mod.linkSystemLibrary("sqlite3", .{});
            // HPACK only. Decoding a header block is the one part of HTTP/2
            // that cannot be skipped by relaying frames untouched.
            mod.addIncludePath(.{ .cwd_relative = bb.pathJoin(&.{ prefix, "include" }) });
            mod.addLibraryPath(.{ .cwd_relative = bb.pathJoin(&.{ prefix, "lib" }) });
            mod.linkSystemLibrary("nghttp2", .{});
            return mod;
        }
    }.make;

    const proxy = b.addExecutable(.{
        .name = "proxy",
        .root_module = proxyModule(b, "examples/proxy/main.zig", target, optimize, tls, ghostty_vt, nghttp2_prefix),
    });
    const proxy_step = b.step("proxy", "Build the pty and TLS proxy example");
    proxy_step.dependOn(&b.addInstallArtifact(proxy, .{}).step);

    const proxy_test_step = b.step("test-proxy", "Run the proxy example's tests");
    for ([_][]const u8{
        "examples/proxy/ca.zig",
        "examples/proxy/tls.zig",
        "examples/proxy/http.zig",
        "examples/proxy/proxy.zig",
        "examples/proxy/db.zig",
        "examples/proxy/h2.zig",
        "examples/proxy/osc.zig",
    }) |path| {
        const tests = b.addTest(.{
            .root_module = proxyModule(b, path, target, optimize, tls, ghostty_vt, nghttp2_prefix),
        });
        proxy_test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // ---------------------------------------------------------------------
    // Other targets
    // ---------------------------------------------------------------------

    // Type-checks the platform files for targets this machine is not. A Windows
    // implementation that silently stopped compiling would otherwise be
    // invisible until somebody on Windows tried to build - which, for a project
    // developed on one machine, means until a user reports it.
    const cross_step = b.step("cross", "Type-check the platform files elsewhere");
    for ([_]std.Target.Query{
        .{ .os_tag = .windows, .cpu_arch = .x86_64 },
        .{ .os_tag = .linux, .cpu_arch = .x86_64, .abi = .gnu },
    }) |query| {
        const cross_target = b.resolveTargetQuery(query);
        const check = b.addObject(.{
            .name = b.fmt("platform-{s}", .{@tagName(query.os_tag.?)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/frontend/platform/root.zig"),
                .target = cross_target,
                .optimize = .Debug,
            }),
        });
        cross_step.dependOn(&check.step);
        const raster_check = b.addLibrary(.{
            .name = b.fmt("text-rasterizer-{s}", .{@tagName(query.os_tag.?)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/frontend/graphics/rasterizer.zig"),
                .target = cross_target,
                .optimize = .Debug,
                .link_libc = true,
            }),
            .linkage = .static,
        });
        raster_check.root_module.addImport(
            "freetype",
            addFreeType(b, cross_target, .Debug),
        );
        cross_step.dependOn(&raster_check.step);
        if (query.os_tag.? == .linux) {
            const cross_unicode = b.createModule(.{
                .root_source_file = b.path("src/core/unicode_fake.zig"),
                .target = cross_target,
                .optimize = .Debug,
            });
            const cross_core = b.createModule(.{
                .root_source_file = b.path("src/core/root.zig"),
                .target = cross_target,
                .optimize = .Debug,
            });
            cross_core.addImport("unicode", cross_unicode);
            const local_transport_check = b.addObject(.{
                .name = "local-transport-linux",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/backend/transport/local.zig"),
                    .target = cross_target,
                    .optimize = .Debug,
                    .link_libc = true,
                }),
            });
            local_transport_check.root_module.addImport("telar-core", cross_core);
            cross_step.dependOn(&local_transport_check.step);
        }
    }
    test_step.dependOn(cross_step);
}

/// Builds the same static FreeType and HarfBuzz sources Ghostty uses for font
/// faces and shaping. Telar leaves system zlib disabled, so FreeType's bundled
/// gzip decoder remains self-contained and the frontend gains no runtime
/// library dependency.
fn addFreeType(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const upstream = b.dependency("freetype", .{});
    const harfbuzz = b.dependency("harfbuzz", .{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/frontend/graphics/freetype.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.abi != .msvc,
    });
    module.addIncludePath(upstream.path("include"));
    module.addIncludePath(harfbuzz.path("src"));
    const flags: []const []const u8 = if (target.result.os.tag == .windows)
        &.{
            "-DFT2_BUILD_LIBRARY",
            "-fno-sanitize=undefined",
        }
    else
        &.{
            "-DFT2_BUILD_LIBRARY",
            "-DHAVE_UNISTD_H",
            "-DHAVE_FCNTL_H",
            "-fno-sanitize=undefined",
        };
    module.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = freetype_sources,
        .flags = flags,
    });
    module.addCSourceFile(.{
        .file = if (target.result.os.tag == .linux)
            upstream.path("builds/unix/ftsystem.c")
        else if (target.result.os.tag == .windows)
            upstream.path("builds/windows/ftsystem.c")
        else
            upstream.path("src/base/ftsystem.c"),
        .flags = flags,
    });
    module.addCSourceFile(.{
        .file = if (target.result.os.tag == .windows)
            upstream.path("builds/windows/ftdebug.c")
        else
            upstream.path("src/base/ftdebug.c"),
        .flags = flags,
    });
    const harfbuzz_flags: []const []const u8 = if (target.result.os.tag == .windows)
        &.{
            "-DHAVE_STDBOOL_H",
            "-DHAVE_FREETYPE=1",
            "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_DONE_MM_VAR=1",
            "-DHAVE_FT_GET_TRANSFORM=1",
            "-fno-sanitize=undefined",
        }
    else
        &.{
            "-DHAVE_STDBOOL_H",
            "-DHAVE_UNISTD_H",
            "-DHAVE_SYS_MMAN_H",
            "-DHAVE_PTHREAD=1",
            "-DHAVE_FREETYPE=1",
            "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_DONE_MM_VAR=1",
            "-DHAVE_FT_GET_TRANSFORM=1",
        };
    module.addCSourceFile(.{
        .file = harfbuzz.path("src/harfbuzz.cc"),
        .flags = harfbuzz_flags,
    });
    return module;
}

const freetype_sources: []const []const u8 = &.{
    "src/autofit/autofit.c",
    "src/base/ftbase.c",
    "src/base/ftbbox.c",
    "src/base/ftbdf.c",
    "src/base/ftbitmap.c",
    "src/base/ftcid.c",
    "src/base/ftfstype.c",
    "src/base/ftgasp.c",
    "src/base/ftglyph.c",
    "src/base/ftgxval.c",
    "src/base/ftinit.c",
    "src/base/ftmm.c",
    "src/base/ftotval.c",
    "src/base/ftpatent.c",
    "src/base/ftpfr.c",
    "src/base/ftstroke.c",
    "src/base/ftsynth.c",
    "src/base/fttype1.c",
    "src/base/ftwinfnt.c",
    "src/bdf/bdf.c",
    "src/bzip2/ftbzip2.c",
    "src/cache/ftcache.c",
    "src/cff/cff.c",
    "src/cid/type1cid.c",
    "src/gzip/ftgzip.c",
    "src/lzw/ftlzw.c",
    "src/pcf/pcf.c",
    "src/pfr/pfr.c",
    "src/psaux/psaux.c",
    "src/pshinter/pshinter.c",
    "src/psnames/psnames.c",
    "src/raster/raster.c",
    "src/sdf/sdf.c",
    "src/sfnt/sfnt.c",
    "src/smooth/smooth.c",
    "src/svg/svg.c",
    "src/truetype/truetype.c",
    "src/type1/type1.c",
    "src/type42/type42.c",
    "src/winfonts/winfnt.c",
};

fn addLua(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
) *std.Build.Module {
    const source_root = b.path("vendor/lua-5.5.1/src");
    const lua = b.addLibrary(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
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
    if (target.result.os.tag != .windows)
        lua.root_module.linkSystemLibrary("m", .{});

    const api = b.createModule(.{
        .root_source_file = b.path("src/frontend/config/lua_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    api.addIncludePath(source_root);
    api.linkLibrary(lua);
    return api;
}
