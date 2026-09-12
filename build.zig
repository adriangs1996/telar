const std = @import("std");
const Coverage = @import("build/Coverage.zig");
const Suite = @import("build/Suite.zig");
const SuiteModules = @import("build/SuiteModules.zig");
const FreeTypeConfig = @import("build/FreeTypeConfig.zig");
const LuaConfig = @import("build/LuaConfig.zig");
const LuaModules = @import("build/LuaModules.zig");

const source_roots: []const []const u8 = &.{ "build.zig", "build", "src", "examples", "benchmarks", "test", "linters" };

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

    const ghostty_dep = b.dependency("ghostty_vt", .{
        .target = target,
        .optimize = vt_optimize,
    });
    const ghostty_vt = ghostty_dep.module("ghostty-vt");
    const wuffs_dep = ghostty_dep.builder.lazyDependency("wuffs", .{
        .target = target,
        .optimize = vt_optimize,
    }) orelse return;
    const wuffs = wuffs_dep.module("wuffs");
    coverage.excludeCSourceCoverage(b, ghostty_vt);
    coverage.excludeCSourceCoverage(b, wuffs);

    const lua_api = addLua(b, .{ .target = target, .optimize = optimize, .name = "lua" });
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
    const client = addClientModule(b, core, .{ .api = lua_api, .telar = telar_lua });
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
    const freetype = addFreeType(b, .{ .target = target, .optimize = optimize, .disable_coverage = coverage.enabled });
    frontend.addImport("telar-core", core);
    frontend.addImport("telar-client", client);
    frontend.addImport("kitty_protocol", kitty_protocol);
    frontend.addImport("telar-lua", telar_lua);
    frontend.addImport("lua-api", lua_api);
    frontend.addImport("freetype", freetype);
    const assets = addAssets(b, target, optimize);
    frontend.addImport("assets", assets);
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

    // Benchmarks use their own optimized module graph. Running a Debug core
    // under a ReleaseFast benchmark executable would measure safety checks and
    // make the result depend on whichever build command happened to run it.
    const bench_optimize: std.builtin.OptimizeMode = if (optimize == .Debug)
        .ReleaseFast
    else
        optimize;
    const bench_lua_api = addLua(b, .{ .target = target, .optimize = bench_optimize, .name = "lua-bench" });
    const bench_lua = b.createModule(.{
        .root_source_file = b.path("src/lua/lua.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_lua.addImport("lua-api", bench_lua_api);
    const bench_unicode = b.createModule(.{
        .root_source_file = b.path("src/core/unicode.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_unicode.addImport("ghostty-vt", ghostty_vt);
    const bench_core = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_core.addImport("unicode", bench_unicode);
    const bench_backend = b.createModule(.{
        .root_source_file = b.path("src/backend/backend.zig"),
        .target = target,
        .optimize = bench_optimize,
        .link_libc = true,
    });
    bench_backend.addImport("telar-core", bench_core);
    bench_backend.addImport("ghostty-vt", ghostty_vt);
    bench_backend.addImport("wuffs", wuffs);
    bench_backend.addImport("tls", tls);
    bench_backend.addImport("telar-lua", bench_lua);
    bench_backend.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ nghttp2_prefix, "include" }) });
    bench_backend.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ nghttp2_prefix, "lib" }) });
    bench_backend.linkSystemLibrary("nghttp2", .{});
    bench_backend.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ brotli_prefix, "include" }) });
    bench_backend.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ brotli_prefix, "lib" }) });
    bench_backend.linkSystemLibrary("brotlidec", .{});
    bench_backend.linkSystemLibrary("sqlite3", .{});
    const bench_kitty_protocol = b.createModule(.{
        .root_source_file = b.path("src/kitty_protocol/kitty_protocol.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    const bench_client = addClientModule(b, bench_core, .{ .api = bench_lua_api, .telar = bench_lua });
    const bench_frontend = b.createModule(.{
        .root_source_file = b.path("src/frontend/frontend.zig"),
        .target = target,
        .optimize = bench_optimize,
        .link_libc = true,
    });
    const bench_freetype = addFreeType(b, .{ .target = target, .optimize = bench_optimize, .disable_coverage = false });
    bench_frontend.addImport("telar-core", bench_core);
    bench_frontend.addImport("telar-client", bench_client);
    bench_frontend.addImport("kitty_protocol", bench_kitty_protocol);
    bench_frontend.addImport("lua-api", bench_lua_api);
    bench_frontend.addImport("telar-lua", bench_lua);
    bench_frontend.addImport("freetype", bench_freetype);
    bench_frontend.addImport("assets", addAssets(b, target, bench_optimize));

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
    benchmarks.root_module.addImport("telar-client", bench_client);

    const echo_probe = b.addExecutable(.{
        .name = "echo-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/echo_probe.zig"),
            .target = target,
            .optimize = bench_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "ghostty-vt", .module = ghostty_vt },
                .{ .name = "telar-backend", .module = bench_backend },
                .{ .name = "telar-frontend", .module = bench_frontend },
                .{ .name = "telar-core", .module = bench_core },
                .{ .name = "telar-client", .module = bench_client },
            },
        }),
    });
    b.step("echo-probe", "Build the echo VT oracle and minimal interposition controls").dependOn(&b.addInstallArtifact(echo_probe, .{}).step);
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
    // The experiment
    // ---------------------------------------------------------------------

    const experiment_module = b.createModule(.{
        .root_source_file = b.path("exper.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    experiment_module.addImport("telar-frontend", frontend);
    experiment_module.addImport("telar-core", core);
    const experiment = b.addExecutable(.{ .name = "exper", .root_module = experiment_module });
    const run_experiment = b.addRunArtifact(experiment);
    b.step("exper", "Run the frontend execution experiment").dependOn(&run_experiment.step);
    if (target.result.os.tag == .macos) {
        const native_module = b.createModule(.{
            .root_source_file = b.path("exper_native.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        native_module.addImport("telar-frontend", frontend);
        native_module.addImport("telar-core", core);
        native_module.addCSourceFile(.{ .file = b.path("exper/native.m"), .flags = &.{"-fobjc-arc"} });
        native_module.linkFramework("AppKit", .{});
        const native = b.addExecutable(.{ .name = "exper-native", .root_module = native_module });
        b.step("build-exper-native", "Build the macOS frontend experiment").dependOn(&native.step);
        b.step("exper-native", "Run the macOS frontend experiment").dependOn(&b.addRunArtifact(native).step);
    }
    const experiment_tests = b.addTest(.{ .root_module = experiment_module });
    b.step("test-exper", "Test the frontend execution experiment").dependOn(&b.addRunArtifact(experiment_tests).step);

    // ---------------------------------------------------------------------
    // The native client
    // ---------------------------------------------------------------------

    // Application packaging. The shipped binary is the same `telar`; a bundle
    // adds a launcher that runs `telar gui --login-shell`, and a desktop file
    // does the same on Linux. See docs/packaging.md.
    if (target.result.os.tag == .macos) {
        const launcher = b.addExecutable(.{
            .name = "Telar",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/launcher/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const bundle_step = b.step("bundle", "Assemble zig-out/Telar.app");
        const contents = "Telar.app/Contents";
        // Case-folding file systems cannot hold `Telar` and `telar` side by side.
        bundle_step.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = contents ++ "/Resources/bin" } } }).step);
        bundle_step.dependOn(&b.addInstallArtifact(launcher, .{ .dest_dir = .{ .override = .{ .custom = contents ++ "/MacOS" } } }).step);
        bundle_step.dependOn(&b.addInstallFile(b.path("packaging/macos/Info.plist"), contents ++ "/Info.plist").step);
        bundle_step.dependOn(&b.addInstallFile(b.path("packaging/macos/telar.icns"), contents ++ "/Resources/telar.icns").step);

        const dmg = b.addSystemCommand(&.{
            "hdiutil",    "create",
            "-volname",   "Telar",
            "-srcfolder", b.getInstallPath(.prefix, "Telar.app"),
            "-ov",        "-format",
            "UDZO",       b.getInstallPath(.prefix, "Telar.dmg"),
        });
        dmg.step.dependOn(bundle_step);
        b.step("dmg", "Build zig-out/Telar.dmg from the bundle").dependOn(&dmg.step);
    } else if (target.result.os.tag == .linux) {
        const desktop = b.addInstallFile(b.path("packaging/linux/telar.desktop"), "share/applications/telar.desktop");
        const icon = b.addInstallFile(b.path("packaging/linux/telar.png"), "share/icons/hicolor/512x512/apps/telar.png");
        b.getInstallStep().dependOn(&desktop.step);
        b.getInstallStep().dependOn(&icon.step);

        const archive_name = b.fmt("telar-{s}-linux.tar.gz", .{@tagName(target.result.cpu.arch)});
        const archive = b.addSystemCommand(&.{ "tar", "-czf", b.getInstallPath(.prefix, archive_name), "-C", b.install_path, "bin", "share" });
        archive.step.dependOn(b.getInstallStep());
        b.step("package-linux", "Build zig-out/telar-<arch>-linux.tar.gz with the binary, desktop entry and icon").dependOn(&archive.step);
    }

    // GPU chrome over the same client behavior as the TUI. It never imports
    // `telar-frontend`; the window and Metal backend are Objective-C compiled
    // by Zig, so the toolchain stays a Zig compiler and the macOS SDK.
    var gui_module: ?*std.Build.Module = null;
    if (target.result.os.tag == .macos or target.result.os.tag == .linux) {
        const gui = b.createModule(.{
            .root_source_file = b.path("src/gui/gui.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        gui.addImport("freetype", freetype);
        gui.addImport("assets", assets);
        gui.addImport("telar-client", client);
        gui.addImport("telar-core", core);
        if (target.result.os.tag == .macos) {
            gui.addCSourceFile(.{
                .file = b.path("src/gui/macos/window.m"),
                .flags = cFlags(b, &.{"-fobjc-arc"}, coverage.enabled),
            });
            gui.linkFramework("AppKit", .{});
            gui.linkFramework("Metal", .{});
            gui.linkFramework("QuartzCore", .{});
        } else {
            addLinuxGuiBackend(b, gui, coverage.enabled);
        }
        exe.root_module.addImport("telar-gui", gui);
        const run_gui = b.addRunArtifact(exe);
        run_gui.addArg("gui");
        if (b.args) |args| {
            run_gui.addArgs(args);
        }
        b.step("gui", "Run the native client through `telar gui`").dependOn(&run_gui.step);
        gui_module = gui;
        const gui_tests = b.addTest(.{ .root_module = gui });
        coverage.instrumentTest(gui_tests);
        b.step("test-gui", "Run the native client tests").dependOn(&b.addRunArtifact(gui_tests).step);
    }

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    const test_step = b.step("test", "Run the tests");
    const client_tests = b.addTest(.{ .root_module = client });
    coverage.instrumentTest(client_tests);
    const run_client_tests = b.addRunArtifact(client_tests);
    const client_boundaries = b.addSystemCommand(&.{ "python3", b.pathFromRoot("tools/check_client_boundaries.py"), "--root", b.pathFromRoot("src/client") });
    const boundary_tests = b.addSystemCommand(&.{ "python3", b.pathFromRoot("tools/test_client_boundaries.py") });
    boundary_tests.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    client_boundaries.step.dependOn(&boundary_tests.step);
    run_client_tests.step.dependOn(&client_boundaries.step);
    b.step("check-client-boundaries", "Check shared-client module and capability boundaries").dependOn(&client_boundaries.step);
    b.step("test-client", "Run renderer-independent client tests").dependOn(&run_client_tests.step);
    test_step.dependOn(&run_client_tests.step);
    // ZLS uses "check" on save. Test artifacts are analyzed without codegen;
    // source validators run separately and never execute application tests.
    const check_step = b.step("check", "Analyze test suites and validate source organization");
    const inventory_tests = b.addSystemCommand(&.{ "python3", b.pathFromRoot("tools/test_compare_zig_tests.py") });
    inventory_tests.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    test_step.dependOn(&inventory_tests.step);
    check_step.dependOn(&inventory_tests.step);
    const client_check = b.addTest(.{ .root_module = client });
    check_step.dependOn(&client_check.step);
    check_step.dependOn(&client_boundaries.step);
    const check_client = b.step("check-client", "Semantic-analyze only the shared client");
    check_client.dependOn(&client_check.step);
    check_client.dependOn(&client_boundaries.step);
    // The shared client depends on core and the Lua modules only; the checker
    // in tools/ enforces the same set at source level.
    std.debug.assert(client.import_table.count() == 3 and client.import_table.get("telar-core").? == core);
    std.debug.assert(client.import_table.get("telar-lua").? == telar_lua and client.import_table.get("lua-api").? == lua_api);

    for (core.import_table.values()) |dependency| {
        std.debug.assert(dependency != client and dependency != frontend and dependency != backend);
    }

    for (backend.import_table.values()) |dependency| {
        std.debug.assert(dependency != client and dependency != frontend);
    }

    for (frontend.import_table.values()) |dependency| {
        std.debug.assert(dependency != backend);
    }

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
    }

    // Flags such as `-- --fix` refine the run; only explicit paths replace the roots.
    if (!argsNamePaths(b.args)) {
        run_codestyle.addArgs(source_roots);
    }
    b.step("codestyle", "Check or fix deterministic Zig code style rules").dependOn(&run_codestyle.step);

    const check_codestyle = b.addRunArtifact(codestyle_exe);
    check_codestyle.addArgs(source_roots);
    check_codestyle.has_side_effects = true;
    check_step.dependOn(&check_codestyle.step);
    test_step.dependOn(&check_codestyle.step);

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
    const media_tests = b.addTest(.{ .root_module = backend, .filters = &.{"PNG"} });
    b.step("test-png", "Run PNG decoding and pane ingestion tests").dependOn(&b.addRunArtifact(media_tests).step);
    const isolation_tests = b.addTest(.{ .root_module = backend, .filters = &.{"performance probe"} });
    const isolation_step = b.step("test-isolation", "Measure bounded search, graphics staging and history query work");
    const isolation_run = b.addRunArtifact(isolation_tests);
    isolation_run.has_side_effects = true;
    isolation_step.dependOn(&isolation_run.step);
    const compression_tests = b.addTest(.{ .root_module = frontend, .filters = &.{"performance probe"} });
    const compression_run = b.addRunArtifact(compression_tests);
    compression_run.has_side_effects = true;
    const compression_step = b.step("test-compression-isolation", "Measure compression work outside presentation turns");
    compression_step.dependOn(&compression_run.step);

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
    release_step.dependOn(&install_exe.step);

    const suites = [_]Suite{
        .{ .path = "src/kitty_protocol/kitty_protocol.zig" },
        .{ .path = "src/core/ui/ui_tests.zig" },
        .{ .path = "src/core/select.zig" },
        // Only referenced through non-pub imports elsewhere, so their tests
        // never run unless they are their own suite roots.
        .{ .path = "src/core/graphics.zig" },
        .{ .path = "src/core/schema/wire.zig", .schema = true },
        .{ .path = "src/core/transport/transport.zig", .transport = true },
        .{ .path = "src/core/diagnostics.zig" },
        .{ .path = "src/core/schema/handshake.zig", .schema = true },
        .{ .path = "src/core/schema_contract_test.zig", .schema = true },
        .{ .path = "src/core/plugin.zig" },
        .{ .path = "src/frontend/ui/ui_tests.zig" },
        // Capability roots can import sibling capabilities, so the package
        // root collects their tests without narrowing Zig's module path.
        .{ .path = "src/frontend/frontend.zig", .libc = true, .frontend = true },
        .{ .path = "src/client/transport/local.zig", .libc = true, .transport = true },
        .{ .path = "src/backend/history/escape.zig" },
        .{ .path = "src/backend/runtime/observability/system_metrics.zig" },
        .{ .path = "src/client/workspace/workspace_list.zig" },
        .{ .path = "src/backend/proxy_test.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/pane/blit.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/pane/damage.zig" },
        .{ .path = "src/backend/history/history_tests.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/pty/pty_tests.zig", .libc = true },
        .{ .path = "src/backend/backend.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/transport/local.zig", .libc = true, .transport = true },
        .{ .path = "src/main.zig", .vt = true, .libc = true },
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
        .client = client,
        .kitty_protocol = kitty_protocol,
        .lua_api = lua_api,
        .telar_lua = telar_lua,
        .tls = tls,
        .freetype = freetype,
        .assets = assets,
        .gui = gui_module,
        .ghostty_vt = ghostty_vt,
        .wuffs = wuffs,
        .nghttp2_prefix = nghttp2_prefix,
        .brotli_prefix = brotli_prefix,
        .target = target,
        .optimize = optimize,
        .build_options = exe_options,
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

    const check_programs = b.step("check-programs", "Analyze every first-party executable entrypoint");
    for ([_]*std.Build.Step.Compile{ exe, benchmarks, echo_probe }) |program| {
        const analyzed = b.addExecutable(.{ .name = program.name, .root_module = program.root_module });
        check_programs.dependOn(&analyzed.step);
    }
    check_step.dependOn(check_programs);

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
        .{ .os_tag = .linux, .cpu_arch = .aarch64, .abi = .gnu },
    }) |query| {
        const cross_target = b.resolveTargetQuery(query);
        const cross_unicode = b.createModule(.{
            .root_source_file = b.path("src/core/unicode_fake.zig"),
            .target = cross_target,
            .optimize = .Debug,
        });
        const cross_core = b.createModule(.{
            .root_source_file = b.path("src/core/core.zig"),
            .target = cross_target,
            .optimize = .Debug,
        });
        cross_core.addImport("unicode", cross_unicode);
        // Platform code publishes shared client values such as `LocalTime`, and
        // sound policy is shared configuration, so both checks need the client
        // module and, through it, the vendored Lua for that target.
        const cross_lua_api = addLua(b, .{
            .target = cross_target,
            .optimize = .Debug,
            .name = b.fmt("lua-{s}-{s}", .{ @tagName(query.os_tag.?), @tagName(query.cpu_arch.?) }),
        });
        const cross_telar_lua = b.createModule(.{
            .root_source_file = b.path("src/lua/lua.zig"),
            .target = cross_target,
            .optimize = .Debug,
            .link_libc = true,
        });
        cross_telar_lua.addImport("lua-api", cross_lua_api);
        const cross_client = addClientModule(b, cross_core, .{ .api = cross_lua_api, .telar = cross_telar_lua });
        const check = b.addObject(.{
            .name = b.fmt("platform-{s}-{s}", .{ @tagName(query.os_tag.?), @tagName(query.cpu_arch.?) }),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/frontend/platform/platform.zig"),
                .target = cross_target,
                .optimize = .Debug,
            }),
        });
        check.root_module.addImport("telar-client", cross_client);
        cross_step.dependOn(&check.step);
        const raster_check = b.addLibrary(.{
            .name = b.fmt("text-rasterizer-{s}-{s}", .{ @tagName(query.os_tag.?), @tagName(query.cpu_arch.?) }),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/frontend/graphics/rasterizer_support.zig"),
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
        raster_check.root_module.addImport("assets", addAssets(b, cross_target, .Debug));
        cross_step.dependOn(&raster_check.step);
        const sound_check = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/frontend/sound/sound_tests.zig"),
                .target = cross_target,
                .optimize = .Debug,
                .link_libc = true,
            }),
        });
        sound_check.root_module.addImport("telar-core", cross_core);
        sound_check.root_module.addImport("telar-client", cross_client);
        if (query.os_tag.? == .windows) {
            sound_check.root_module.linkSystemLibrary("user32", .{});
        }
        cross_step.dependOn(&sound_check.step);
        if (query.os_tag.? == .linux) {
            // Compile the tests so their calls analyze listener bodies too.
            // An object containing only unused public functions misses errors.
            const local_transport_check = b.addTest(.{
                .name = b.fmt("local-transport-linux-{s}", .{@tagName(query.cpu_arch.?)}),
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

// Configuration and plugins are shared client behavior, so the common client
// owns the Lua modules; adapters never load configuration themselves.
fn addClientModule(b: *std.Build, core: *std.Build.Module, lua: LuaModules) *std.Build.Module {
    const client = b.createModule(.{
        .root_source_file = b.path("src/client/client.zig"),
        .target = core.resolved_target,
        .optimize = core.optimize,
        .link_libc = true,
    });

    client.addImport("telar-core", core);
    client.addImport("telar-lua", lua.telar);
    client.addImport("lua-api", lua.api);
    return client;
}

// The shared modules every test suite links against, so the run instances and
// the analysis-only `check` twins are wired identically from one place.

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

// Root fuzz instrumentation also reaches linked C-family sources. zcov's
// runtime does not provide every callback those sources emit, so keep native
// dependencies outside the coverage graph.
const no_c_coverage = "-fno-sanitize-coverage=trace-pc-guard,trace-cmp,inline-8bit-counters,pc-table";

pub fn cFlags(b: *std.Build, base: []const []const u8, disable_coverage: bool) []const []const u8 {
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
        .root_source_file = b.path("src/lua/lua_api.zig"),
        .target = target,
        .optimize = config.optimize,
        .link_libc = true,
    });
    api.addIncludePath(source_root);
    api.linkLibrary(lua);
    return api;
}

fn argsNamePaths(args: ?[]const []const u8) bool {
    for (args orelse return false) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            return true;
        }
    }

    return false;
}

fn addAssets(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/assets/assets.zig"),
        .target = target,
        .optimize = optimize,
    });
}

/// Wayland through xdg-shell and Vulkan through the system loader. The
/// xdg-shell client code is generated from the protocol the distribution
/// installs, so the machine building Telar needs `wayland-scanner`,
/// `wayland-protocols` and the Vulkan headers.
fn addLinuxGuiBackend(b: *std.Build, gui: *std.Build.Module, disable_coverage: bool) void {
    const protocol = "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml";
    const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header", protocol });
    const header_file = header.addOutputFileArg("xdg-shell-client-protocol.h");
    const code = b.addSystemCommand(&.{ "wayland-scanner", "private-code", protocol });
    const code_file = code.addOutputFileArg("xdg-shell-protocol.c");
    const flags = cFlags(b, &.{"-std=c11"}, disable_coverage);
    gui.addIncludePath(header_file.dirname());
    gui.addCSourceFile(.{ .file = code_file, .flags = flags });
    gui.addCSourceFile(.{ .file = b.path("src/gui/linux/window.c"), .flags = flags });
    gui.addCSourceFile(.{ .file = b.path("src/gui/linux/renderer.c"), .flags = flags });
    gui.addCSourceFile(.{ .file = spirvSource(b, "quad.vert", "telar_gui_quad_vert_spv"), .flags = flags });
    gui.addCSourceFile(.{ .file = spirvSource(b, "quad.frag", "telar_gui_quad_frag_spv"), .flags = flags });
    gui.linkSystemLibrary("wayland-client", .{});
    gui.linkSystemLibrary("vulkan", .{});
}

/// Embeds a compiled shader as a C array so every binary that links the
/// Linux backend carries it. Regenerate the `.spv` with `glslc` after editing
/// the GLSL next to it.
fn spirvSource(b: *std.Build, shader: []const u8, symbol: []const u8) std.Build.LazyPath {
    const spv_path = b.fmt("src/gui/shaders/{s}.spv", .{shader});
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, b.pathFromRoot(spv_path), b.allocator, .limited(1 << 20)) catch |err| {
        std.debug.panic("cannot read {s}: {s}", .{ spv_path, @errorName(err) });
    };
    std.debug.assert(bytes.len % 4 == 0);
    var source: std.Io.Writer.Allocating = .init(b.allocator);
    const writer = &source.writer;
    writer.print("#include <stdint.h>\nconst uint32_t {s}_bytes = {d};\nconst uint32_t {s}[] = {{", .{ symbol, bytes.len, symbol }) catch @panic("OOM");
    var index: usize = 0;
    while (index < bytes.len) : (index += 4) {
        writer.print("{s}0x{x:0>8}", .{ if (index == 0) "" else ",", std.mem.readInt(u32, bytes[index..][0..4], .little) }) catch @panic("OOM");
    }
    writer.writeAll("};\n") catch @panic("OOM");
    return b.addWriteFiles().add(b.fmt("{s}.c", .{symbol}), source.written());
}
