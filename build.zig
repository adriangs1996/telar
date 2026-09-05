const std = @import("std");

const ProxyPrefixes = struct {
    nghttp2: []const u8,
    brotli: []const u8,
};

const ProxyModuleConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tls: *std.Build.Module,
    vt: *std.Build.Module,
    prefixes: ProxyPrefixes,
};

const FreeTypeConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    disable_coverage: bool,
};

const LuaConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
};

pub fn build(b: *std.Build) void {
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

    const ghostty_vt = b.dependency("ghostty_vt", .{
        .target = target,
        .optimize = vt_optimize,
    }).module("ghostty-vt");
    coverage.excludeCSourceCoverage(b, ghostty_vt);

    const lua_api = addLua(b, .{ .target = target, .optimize = optimize, .name = "lua" });
    coverage.instrumentModule(lua_api);
    const telar_lua = b.addModule("telar-lua", .{
        .root_source_file = b.path("src/lua/root.zig"),
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

    // These module edges are the process boundary in code before IPC exists.
    // Both sides may import core. They cannot import each other.
    const core = b.addModule("telar-core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core.addImport("unicode", unicode);
    coverage.instrumentModule(core);

    const backend = b.addModule("telar-backend", .{
        .root_source_file = b.path("src/backend/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    backend.addImport("telar-core", core);
    backend.addImport("telar-lua", telar_lua);
    backend.addImport("lua-api", lua_api);
    backend.addImport("ghostty-vt", ghostty_vt);
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
        .root_source_file = b.path("src/frontend/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const freetype = addFreeType(b, .{ .target = target, .optimize = optimize, .disable_coverage = coverage.enabled });
    frontend.addImport("telar-core", core);
    frontend.addImport("telar-lua", telar_lua);
    frontend.addImport("lua-api", lua_api);
    frontend.addImport("freetype", freetype);
    if (target.result.os.tag == .macos) {
        frontend.addCSourceFile(.{
            .file = b.path("src/frontend/attachments/darwin.m"),
            .flags = cFlags(b, &.{"-fobjc-arc"}, coverage.enabled),
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
    exe.root_module.addImport("telar-core", core);
    exe.root_module.addImport("ghostty-vt", ghostty_vt);
    const diagnostics_enabled = b.option(
        bool,
        "diagnostics",
        "Collect development telemetry in optimized builds",
    ) orelse false;
    const exe_options = b.addOptions();
    exe_options.addOption(bool, "diagnostics", diagnostics_enabled);
    exe.root_module.addOptions("build_options", exe_options);
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    run_exe.setEnvironmentVariable(
        "TELAR_DEVELOPMENT_CONFIG",
        b.pathFromRoot("dev/config.lua"),
    );
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    b.step("run", "Run telar").dependOn(&run_exe.step);

    // Benchmarks use their own optimized module graph. Running a Debug core
    // under a ReleaseFast benchmark executable would measure safety checks and
    // make the result depend on whichever build command happened to run it.
    const bench_optimize: std.builtin.OptimizeMode = if (optimize == .Debug)
        .ReleaseFast
    else
        optimize;
    const bench_lua_api = addLua(b, .{ .target = target, .optimize = bench_optimize, .name = "lua-bench" });
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
    bench_backend.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ brotli_prefix, "include" }) });
    bench_backend.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ brotli_prefix, "lib" }) });
    bench_backend.linkSystemLibrary("brotlidec", .{});
    bench_backend.linkSystemLibrary("sqlite3", .{});
    const bench_frontend = b.createModule(.{
        .root_source_file = b.path("src/frontend/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .link_libc = true,
    });
    const bench_freetype = addFreeType(b, .{ .target = target, .optimize = bench_optimize, .disable_coverage = false });
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

    const history_preview = b.addExecutable(.{
        .name = "history-preview",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/history_browser.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    history_preview.root_module.addImport("telar-frontend", frontend);
    const run_history_preview = b.addRunArtifact(history_preview);
    if (b.args) |args| {
        run_history_preview.addArgs(args);
    }

    b.step("history-preview", "Render the real history widget as SVG for visual review").dependOn(&run_history_preview.step);

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

    // A deterministic terminal-browser stand-in: publishes shared-memory
    // frames of a chosen size at a chosen rate, so the graphics pipeline can
    // be measured without Chromium.
    const frame_source = b.addExecutable(.{
        .name = "telar-frame-source",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/frame_source.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(frame_source);

    const run_terminal_browser_pane = b.addRunArtifact(terminal_browser_pane);
    run_terminal_browser_pane.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_terminal_browser_pane.addArgs(args);
    }
    b.step(
        "terminal-browser-pane",
        "Run terminal-browser inside a centered half-size pane",
    ).dependOn(&run_terminal_browser_pane.step);

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    const test_step = b.step("test", "Run the tests");
    // zls auto-enables build-on-save when a step named "check" exists, giving
    // editors real compiler diagnostics on every save. The step compiles twin
    // instances of the test suites that nothing installs or runs, so Zig stops
    // after semantic analysis and a save never pays for codegen or linking.
    const check_step = b.step("check", "Semantic-analyze the test suites without running them");
    const codestyle_exe = b.addExecutable(.{
        .name = "codestyle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("linters/codestyle/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_codestyle = b.addRunArtifact(codestyle_exe);
    if (b.args) |args| {
        run_codestyle.addArgs(args);
    } else {
        run_codestyle.addArgs(&.{
            "build.zig",
            "src",
            "examples",
            "benchmarks",
            "test/fuzz/build.zig",
            "test/fuzz/src",
            "linters",
        });
    }
    b.step("codestyle", "Check or fix deterministic Zig code style rules").dependOn(&run_codestyle.step);

    const codestyle_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("linters/codestyle/test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    check_step.dependOn(&codestyle_tests.step);
    test_step.dependOn(&b.addRunArtifact(codestyle_tests).step);
    const parallel_test_prerequisites = testBarrier(b, "run parallel test prerequisites");
    const transport_test_prerequisites = testBarrier(b, "run transport test prerequisites");
    const schema_test_prerequisites = testBarrier(b, "run schema test prerequisites");
    const backend_proxy_test_step = b.step(
        "test-backend-proxy",
        "Run the runtime observation proxy tests",
    );
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
        .{ .path = "src/backend/runtime/observability/system_metrics.zig" },
        .{ .path = "src/frontend/workspace/workspace_list.zig" },
        .{ .path = "src/backend/proxy_test.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/pane/blit.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/pane/damage.zig" },
        .{ .path = "src/backend/history/root.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/pty/root.zig", .libc = true },
        .{ .path = "src/backend/root.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/transport/local.zig", .libc = true, .transport = true },
        .{ .path = "src/main.zig", .vt = true, .libc = true },
        .{ .path = "examples/sidebar.zig", .vt = true, .libc = true },
        .{ .path = "examples/terminal_browser_pane.zig", .vt = true, .libc = true },
        .{
            .path = "src/transport_integration_test.zig",
            .vt = true,
            .libc = true,
            .transport = true,
            .schema = true,
            .isolated = true,
        },
    };
    const suite_modules: SuiteModules = .{
        .unicode = unicode,
        .core = core,
        .backend = backend,
        .frontend = frontend,
        .lua_api = lua_api,
        .telar_lua = telar_lua,
        .tls = tls,
        .freetype = freetype,
        .ghostty_vt = ghostty_vt,
        .nghttp2_prefix = nghttp2_prefix,
        .brotli_prefix = brotli_prefix,
        .target = target,
        .optimize = optimize,
    };
    for (suites) |suite| {
        const tests = suite_modules.addSuiteTest(b, suite);
        coverage.instrumentTest(tests);

        check_step.dependOn(&suite_modules.addSuiteTest(b, suite).step);

        if (suite.isolated) {
            // These PTY, process, and socket tests share finite host resources.
            // Separate runs preserve each test step's scope while ensuring the
            // integration event loops start after that step's other binaries.
            const default_run = isolatedTestRun(b, tests, parallel_test_prerequisites);
            test_step.dependOn(&default_run.step);
            if (suite.transport) {
                const transport_run = isolatedTestRun(b, tests, transport_test_prerequisites);
                transport_test_step.dependOn(&transport_run.step);
            }
            if (suite.schema) {
                const schema_run = isolatedTestRun(b, tests, schema_test_prerequisites);
                schema_test_step.dependOn(&schema_run.step);
            }
            continue;
        }

        const run_tests = b.addRunArtifact(tests);
        parallel_test_prerequisites.dependOn(&run_tests.step);
        if (std.mem.eql(u8, suite.path, "src/backend/proxy_test.zig")) {
            backend_proxy_test_step.dependOn(&run_tests.step);
        }
        if (suite.transport) {
            transport_test_prerequisites.dependOn(&run_tests.step);
        }
        if (suite.schema) {
            schema_test_prerequisites.dependOn(&run_tests.step);
        }
        if (suite.frontend) {
            frontend_test_step.dependOn(&run_tests.step);
        }
    }

    // The same drawing code against a width table that answers nonsense, so
    // the module seam is proven rather than asserted. Only this file's tests
    // run: the ones inside `ui/root.zig` assert real widths and cannot pass here.
    const unicode_fake = b.createModule(.{
        .root_source_file = b.path("src/core/unicode_fake.zig"),
        .target = target,
        .optimize = optimize,
    });
    coverage.instrumentModule(unicode_fake);
    const substitution = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/unicode_substitution_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"injected table"},
    });
    substitution.root_module.addImport("unicode", unicode_fake);
    coverage.instrumentTest(substitution);
    parallel_test_prerequisites.dependOn(&b.addRunArtifact(substitution).step);

    // ---------------------------------------------------------------------
    // The proxy example
    // ---------------------------------------------------------------------

    // Deliberately outside the default build and outside `test`. It needs
    // sqlite3 and libnghttp2 from the system, and telar's whole point is that
    // the core builds anywhere with nothing but a Zig compiler. Someone who
    // wants the proxy asks for it.
    const proxyModule = struct {
        fn make(bb: *std.Build, path: []const u8, config: ProxyModuleConfig) *std.Build.Module {
            const mod = bb.createModule(.{
                .root_source_file = bb.path(path),
                .target = config.target,
                .optimize = config.optimize,
                .link_libc = true,
            });
            mod.addImport("tls", config.tls);
            mod.addImport("ghostty-vt", config.vt);
            mod.linkSystemLibrary("sqlite3", .{});
            // HPACK only. Decoding a header block is the one part of HTTP/2
            // that cannot be skipped by relaying frames untouched.
            mod.addIncludePath(.{ .cwd_relative = bb.pathJoin(&.{ config.prefixes.nghttp2, "include" }) });
            mod.addLibraryPath(.{ .cwd_relative = bb.pathJoin(&.{ config.prefixes.nghttp2, "lib" }) });
            mod.linkSystemLibrary("nghttp2", .{});
            mod.addIncludePath(.{ .cwd_relative = bb.pathJoin(&.{ config.prefixes.brotli, "include" }) });
            mod.addLibraryPath(.{ .cwd_relative = bb.pathJoin(&.{ config.prefixes.brotli, "lib" }) });
            mod.linkSystemLibrary("brotlidec", .{});
            return mod;
        }
    }.make;

    const proxy = b.addExecutable(.{
        .name = "proxy",
        .root_module = proxyModule(b, "examples/proxy/main.zig", .{
            .target = target,
            .optimize = optimize,
            .tls = tls,
            .vt = ghostty_vt,
            .prefixes = .{
                .nghttp2 = nghttp2_prefix,
                .brotli = brotli_prefix,
            },
        }),
    });
    const proxy_step = b.step("proxy", "Build the pty and TLS proxy example");
    proxy_step.dependOn(&b.addInstallArtifact(proxy, .{}).step);

    const proxy_test_step = b.step("test-proxy-example", "Run the proxy example's tests");
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
            .root_module = proxyModule(b, path, .{
                .target = target,
                .optimize = optimize,
                .tls = tls,
                .vt = ghostty_vt,
                .prefixes = .{
                    .nghttp2 = nghttp2_prefix,
                    .brotli = brotli_prefix,
                },
            }),
        });
        coverage.instrumentTest(tests);
        proxy_test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // ---------------------------------------------------------------------
    // Other targets
    // ---------------------------------------------------------------------

    // Type-checks platform-dependent frontend code for targets this machine is
    // not. A Windows implementation that silently stopped compiling would
    // otherwise be
    // invisible until somebody on Windows tried to build - which, for a project
    // developed on one machine, means until a user reports it.
    const cross_step = b.step("cross", "Type-check platform-dependent code elsewhere");
    for ([_]std.Target.Query{
        .{ .os_tag = .windows, .cpu_arch = .x86_64 },
        .{ .os_tag = .linux, .cpu_arch = .x86_64, .abi = .gnu },
    }) |query| {
        const cross_target = b.resolveTargetQuery(query);
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
            addFreeType(b, .{ .target = cross_target, .optimize = .Debug, .disable_coverage = false }),
        );
        cross_step.dependOn(&raster_check.step);
        const sound_check = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/frontend/sound/root.zig"),
                .target = cross_target,
                .optimize = .Debug,
                .link_libc = true,
            }),
        });
        sound_check.root_module.addImport("telar-core", cross_core);
        if (query.os_tag.? == .windows) {
            sound_check.root_module.linkSystemLibrary("user32", .{});
        }
        cross_step.dependOn(&sound_check.step);
        if (query.os_tag.? == .linux) {
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
    parallel_test_prerequisites.dependOn(cross_step);
}

const Suite = struct {
    path: []const u8,
    vt: bool = false,
    libc: bool = false,
    transport: bool = false,
    schema: bool = false,
    frontend: bool = false,
    isolated: bool = false,
};

// The shared modules every test suite links against, so the run instances and
// the analysis-only `check` twins are wired identically from one place.
const SuiteModules = struct {
    unicode: *std.Build.Module,
    core: *std.Build.Module,
    backend: *std.Build.Module,
    frontend: *std.Build.Module,
    lua_api: *std.Build.Module,
    telar_lua: *std.Build.Module,
    tls: *std.Build.Module,
    freetype: *std.Build.Module,
    ghostty_vt: *std.Build.Module,
    nghttp2_prefix: []const u8,
    brotli_prefix: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    fn addSuiteTest(modules: SuiteModules, b: *std.Build, suite: Suite) *std.Build.Step.Compile {
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
        tests.root_module.addImport("lua-api", modules.lua_api);
        tests.root_module.addImport("telar-lua", modules.telar_lua);
        tests.root_module.addImport("tls", modules.tls);
        tests.root_module.addImport("freetype", modules.freetype);
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
};

fn testBarrier(b: *std.Build, name: []const u8) *std.Build.Step {
    const barrier = b.allocator.create(std.Build.Step) catch @panic("OOM");
    barrier.* = std.Build.Step.init(.{ .id = .custom, .name = name, .owner = b });
    return barrier;
}

fn isolatedTestRun(b: *std.Build, tests: *std.Build.Step.Compile, prerequisites: *std.Build.Step) *std.Build.Step.Run {
    const run = b.addRunArtifact(tests);
    run.step.dependOn(prerequisites);
    return run;
}

const Coverage = struct {
    enabled: bool,
    runtime_path: ?[]const u8,

    fn init(b: *std.Build) Coverage {
        const enabled = b.option(bool, "coverage", "Enable zig-cov instrumentation") orelse false;
        const runtime_path = b.option([]const u8, "coverage-rt", "Path to zig-cov-rt.o");
        if (enabled and runtime_path == null) {
            std.debug.panic("-Dcoverage requires -Dcoverage-rt=<path>", .{});
        }
        return .{
            .enabled = enabled,
            .runtime_path = runtime_path,
        };
    }

    fn instrumentModule(coverage: Coverage, module: *std.Build.Module) void {
        if (coverage.enabled) {
            module.fuzz = true;
        }
    }

    fn instrumentTest(coverage: Coverage, test_executable: *std.Build.Step.Compile) void {
        if (!coverage.enabled) {
            return;
        }
        test_executable.use_llvm = true;
        test_executable.root_module.fuzz = true;
        test_executable.root_module.link_libc = true;
        test_executable.root_module.addObjectFile(.{ .cwd_relative = coverage.runtime_path.? });
    }

    fn excludeCSourceCoverage(coverage: Coverage, b: *std.Build, module: *std.Build.Module) void {
        if (!coverage.enabled) {
            return;
        }
        for (module.link_objects.items) |link_object| switch (link_object) {
            .c_source_file => |source| source.flags = cFlags(b, source.flags, true),
            .c_source_files => |sources| sources.flags = cFlags(b, sources.flags, true),
            else => {},
        };
    }
};

// Root fuzz instrumentation also reaches linked C-family sources. zcov's
// runtime does not provide every callback those sources emit, so keep native
// dependencies outside the coverage graph.
const no_c_coverage = "-fno-sanitize-coverage=trace-pc-guard,trace-cmp,inline-8bit-counters,pc-table";

fn cFlags(b: *std.Build, base: []const []const u8, disable_coverage: bool) []const []const u8 {
    if (!disable_coverage) {
        return base;
    }
    const flags = b.allocator.alloc([]const u8, base.len + 1) catch @panic("OOM");
    @memcpy(flags[0..base.len], base);
    flags[base.len] = no_c_coverage;
    return flags;
}

/// Builds the same static FreeType and HarfBuzz sources Ghostty uses for font
/// faces and shaping. Telar leaves system zlib disabled, so FreeType's bundled
/// gzip decoder remains self-contained and the frontend gains no runtime
/// library dependency.
fn addFreeType(b: *std.Build, config: FreeTypeConfig) *std.Build.Module {
    const target = config.target;
    const disable_coverage = config.disable_coverage;
    const upstream = b.dependency("freetype", .{});
    const harfbuzz = b.dependency("harfbuzz", .{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/frontend/graphics/freetype.zig"),
        .target = target,
        .optimize = config.optimize,
        .link_libc = true,
        .link_libcpp = target.result.abi != .msvc,
    });
    module.addIncludePath(upstream.path("include"));
    module.addIncludePath(harfbuzz.path("src"));
    const base_flags: []const []const u8 = if (target.result.os.tag == .windows)
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
    const flags = cFlags(b, base_flags, disable_coverage);
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
    const harfbuzz_base_flags: []const []const u8 = if (target.result.os.tag == .windows)
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
    const harfbuzz_flags = cFlags(b, harfbuzz_base_flags, disable_coverage);
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

fn addLua(b: *std.Build, config: LuaConfig) *std.Build.Module {
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
        .root_source_file = b.path("src/frontend/config/lua_api.zig"),
        .target = target,
        .optimize = config.optimize,
        .link_libc = true,
    });
    api.addIncludePath(source_root);
    api.linkLibrary(lua);
    return api;
}
