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
    backend.linkSystemLibrary("sqlite3", .{});

    const frontend = b.addModule("telar-frontend", .{
        .root_source_file = b.path("src/frontend/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    frontend.addImport("telar-core", core);

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
    if (b.args) |args| run_exe.addArgs(args);
    b.step("run", "Run telar").dependOn(&run_exe.step);

    // Benchmarks use their own optimized module graph. Running a Debug core
    // under a ReleaseFast benchmark executable would measure safety checks and
    // make the result depend on whichever build command happened to run it.
    const bench_optimize: std.builtin.OptimizeMode = if (optimize == .Debug)
        .ReleaseFast
    else
        optimize;
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
    bench_backend.linkSystemLibrary("sqlite3", .{});
    const bench_frontend = b.createModule(.{
        .root_source_file = b.path("src/frontend/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .link_libc = true,
    });
    bench_frontend.addImport("telar-core", bench_core);

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

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    const test_step = b.step("test", "Run the tests");
    const transport_test_step = b.step("test-transport", "Run the local transport tests");
    const schema_test_step = b.step("test-schema", "Run the shared protocol schema tests");

    const Suite = struct {
        path: []const u8,
        vt: bool = false,
        libc: bool = false,
        transport: bool = false,
        schema: bool = false,
    };
    const suites = [_]Suite{
        .{ .path = "src/core/ui.zig" },
        .{ .path = "src/core/select.zig" },
        // Only referenced through non-pub imports elsewhere, so their tests
        // never run unless they are their own suite roots.
        .{ .path = "src/core/graphics.zig" },
        .{ .path = "src/core/schema/wire.zig", .schema = true },
        .{ .path = "src/core/transport.zig", .transport = true },
        .{ .path = "src/core/endpoint.zig", .transport = true },
        .{ .path = "src/core/diagnostics.zig" },
        .{ .path = "src/core/schema/handshake.zig", .schema = true },
        .{ .path = "src/core/schema_test.zig", .schema = true },
        .{ .path = "src/frontend/ui.zig" },
        .{ .path = "src/frontend/term.zig", .libc = true },
        .{ .path = "src/frontend/frame.zig", .libc = true },
        .{ .path = "src/frontend/pace.zig" },
        .{ .path = "src/frontend/edit.zig" },
        .{ .path = "src/frontend/keybind.zig" },
        .{ .path = "src/frontend/layout.zig" },
        .{ .path = "src/frontend/multiplexer.zig", .libc = true },
        .{ .path = "src/frontend/client.zig", .libc = true },
        .{ .path = "src/frontend/transport/local.zig", .libc = true, .transport = true },
        .{ .path = "src/backend/blit.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/damage.zig" },
        .{ .path = "src/backend/history/root.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/pty.zig", .libc = true },
        .{ .path = "src/backend/runtime.zig", .vt = true, .libc = true },
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
        if (suite.vt) tests.root_module.addImport("ghostty-vt", ghostty_vt);
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
        if (suite.transport) transport_test_step.dependOn(&run_tests.step);
        if (suite.schema) schema_test_step.dependOn(&run_tests.step);
    }

    // The same drawing code against a width table that answers nonsense, so
    // the module seam is proven rather than asserted. Only this file's tests
    // run: the ones inside `ui.zig` assert real widths and cannot pass here.
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
    const tls = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    }).module("tls");

    const nghttp2_prefix = b.option(
        []const u8,
        "nghttp2",
        "Prefix of a libnghttp2 installation",
    ) orelse "/opt/homebrew/opt/libnghttp2";

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
        const check = b.addObject(.{
            .name = b.fmt("platform-{s}", .{@tagName(query.os_tag.?)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/frontend/platform.zig"),
                .target = b.resolveTargetQuery(query),
                .optimize = .Debug,
            }),
        });
        cross_step.dependOn(&check.step);
    }
    test_step.dependOn(cross_step);
}
