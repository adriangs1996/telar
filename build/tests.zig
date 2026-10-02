const std = @import("std");
const Application = @import("Application.zig");
const Benchmarks = @import("Benchmarks.zig");
const Suite = @import("Suite.zig");
const Libraries = @import("Libraries.zig");
const model_build = @import("model.zig");
const fuzz_http1 = @import("fuzz_http1.zig");
const fuzz_frames = @import("fuzz_frames.zig");
const fuzz_ipc_client = @import("fuzz_ipc_client.zig");
const fuzz_ipc_server = @import("fuzz_ipc_server.zig");
const fuzz_http2 = @import("fuzz_http2.zig");
const fuzz_imaging = @import("fuzz_imaging.zig");

const source_roots: []const []const u8 = &.{ "build.zig", "build", "lib", "src", "examples", "benchmarks", "linters" };

/// Register tests/checks and return the parallel-test barrier: `tests.add(b, app, bench)`.
pub fn add(b: *std.Build, app: Application, bench: Benchmarks) *std.Build.Step {
    const test_step = b.step("test", "Run the tests");
    const model_tests = b.addTest(
        .{
            .root_module = app.modules.data,
        },
    );
    app.coverage.instrumentTest(model_tests);
    const run_model_tests = b.addRunArtifact(model_tests);
    const model_boundaries = b.addSystemCommand(&.{
        "python3",
        b.pathFromRoot("tools/check_model_boundaries.py"),
        "--root",
        b.pathFromRoot("."),
    });
    const model_boundary_tests = b.addSystemCommand(&.{
        "python3",
        b.pathFromRoot("tools/test_model_boundaries.py"),
    });
    model_boundary_tests.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    model_boundaries.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    model_boundaries.step.dependOn(&model_boundary_tests.step);
    run_model_tests.step.dependOn(&model_boundaries.step);
    b.step("check-model-boundaries", "Check shared model dependency boundaries").dependOn(&model_boundaries.step);
    b.step("test-model", "Run shared model tests without client or adapters").dependOn(&run_model_tests.step);
    test_step.dependOn(&run_model_tests.step);
    const client_tests = b.addTest(.{ .root_module = app.modules.client });
    app.coverage.instrumentTest(client_tests);
    const run_client_tests = b.addRunArtifact(client_tests);
    const client_boundaries = b.addSystemCommand(&.{ "python3", b.pathFromRoot("tools/check_client_boundaries.py"), "--root", b.pathFromRoot("src/client") });
    const boundary_tests = b.addSystemCommand(&.{ "python3", b.pathFromRoot("tools/test_client_boundaries.py") });
    boundary_tests.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    client_boundaries.step.dependOn(&boundary_tests.step);
    client_boundaries.step.dependOn(&model_boundaries.step);
    run_client_tests.step.dependOn(&client_boundaries.step);
    b.step("check-client-boundaries", "Check shared-client module boundaries").dependOn(&client_boundaries.step);
    const client_integration_step = b.step("test-client", "Run renderer-independent client tests");
    client_integration_step.dependOn(&run_client_tests.step);
    test_step.dependOn(&run_client_tests.step);
    const headless_tests = b.addTest(.{ .root_module = app.modules.headless.? });
    const run_headless_tests = b.addRunArtifact(headless_tests);
    b.step("test-headless", "Run the headless client's tests").dependOn(&run_headless_tests.step);
    test_step.dependOn(&run_headless_tests.step);
    // The Lua VM, its sandbox and json.decode test inside their own module;
    // no suite root imports those files.
    const lua_tests = b.addTest(.{ .root_module = app.modules.telar_lua });
    const run_lua_tests = b.addRunArtifact(lua_tests);
    b.step("test-lua", "Run the Lua VM, sandbox and JSON tests").dependOn(&run_lua_tests.step);
    test_step.dependOn(&run_lua_tests.step);
    // ZLS uses "check" on save. Test artifacts are analyzed without codegen;
    // source validators run separately and never execute application tests.
    const check_step = b.step("check", "Analyze test suites and validate source organization");
    test_step.dependOn(app.modules.libraries.addTests(b, app.coverage, check_step));
    const reexports = b.addSystemCommand(&.{ "python3", b.pathFromRoot("tools/check_library_reexports.py"), "--root", b.pathFromRoot(".") });
    const reexport_tests = b.addSystemCommand(&.{ "python3", b.pathFromRoot("tools/test_library_reexports.py") });
    reexports.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    reexport_tests.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    reexports.step.dependOn(&reexport_tests.step);
    b.step("check-library-reexports", "Check that packages import libraries instead of re-exporting them").dependOn(&reexports.step);
    check_step.dependOn(&reexports.step);
    test_step.dependOn(&reexports.step);
    const inventory_tests = b.addSystemCommand(&.{ "python3", b.pathFromRoot("tools/test_compare_zig_tests.py") });
    inventory_tests.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    test_step.dependOn(&inventory_tests.step);
    check_step.dependOn(&inventory_tests.step);
    // The placement experiment's allocator needs only `std` and the value
    // files beside it, so it tests without the benchmark's module graph; its
    // runner tests against a stand-in executable and measures nothing.
    const placement_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/PlacementAllocator.zig"),
        .target = app.modules.target,
        .optimize = app.modules.optimize,
    });
    const placement_runner_tests = b.addSystemCommand(&.{ "python3", b.pathFromRoot("tools/test_placement_bench.py") });
    placement_runner_tests.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    const placement_step = b.step("test-bench-placement", "Run the placement benchmark's allocator and runner tests");
    placement_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = placement_module })).step);
    placement_step.dependOn(&placement_runner_tests.step);
    test_step.dependOn(placement_step);
    check_step.dependOn(&b.addTest(.{ .root_module = placement_module }).step);
    const model_check = b.addTest(
        .{
            .root_module = app.modules.data,
        },
    );
    check_step.dependOn(&model_check.step);
    const client_check = b.addTest(.{ .root_module = app.modules.client });
    check_step.dependOn(&client_check.step);
    check_step.dependOn(&b.addTest(.{ .root_module = app.modules.telar_lua }).step);
    check_step.dependOn(&client_boundaries.step);
    const check_client = b.step("check-client", "Semantic-analyze only the shared client");
    check_client.dependOn(&client_check.step);
    check_client.dependOn(&client_boundaries.step);
    // The shared client depends on model, core, the Lua modules and the
    // libraries; the checker in tools/ enforces the same set at source level.
    std.debug.assert(app.modules.client.import_table.count() == 4 + app.modules.libraries.modules.len and app.modules.client.import_table.get("telar-core").? == app.modules.core);
    std.debug.assert(app.modules.client.import_table.get("telar-lua").? == app.modules.telar_lua and app.modules.client.import_table.get("lua-api").? == app.modules.lua_api);

    std.debug.assert(app.modules.client.import_table.get("model").? == app.modules.data);
    std.debug.assert(app.modules.data.import_table.count() == 1 + model_build.libraries.len and app.modules.data.import_table.get("telar-core").? == app.modules.core);

    for (app.modules.core.import_table.values()) |dependency| {
        std.debug.assert(dependency != app.modules.client and dependency != app.modules.backend);
    }

    for (app.modules.backend.import_table.values()) |dependency| {
        std.debug.assert(dependency != app.modules.client);
    }

    const codestyle_exe = b.addExecutable(.{
        .name = "codestyle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("linters/codestyle/main.zig"),
            .target = b.graph.host,
            .optimize = app.modules.optimize,
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
            .optimize = app.modules.optimize,
        }),
    });
    check_step.dependOn(&codestyle_tests.step);
    test_step.dependOn(&b.addRunArtifact(codestyle_tests).step);
    const parallel_test_prerequisites = testBarrier(b, "run parallel test prerequisites");
    const transport_test_prerequisites = testBarrier(b, "run transport test prerequisites");
    const schema_test_prerequisites = testBarrier(b, "run schema test prerequisites");
    const backend_proxy_test_step = b.step(
        "test-backend-proxy",
        "Run the runtime proxy tests",
    );
    const editor_tests = b.addTest(.{ .root_module = app.modules.backend, .filters = &.{"editor"} });
    const editor_wire_tests = b.addTest(.{ .root_module = app.modules.core, .filters = &.{ "editor", "corpus", "every truncated prefix" } });
    const editor_step = b.step("test-editors", "Verify editor discovery, identity and literal file opening");
    editor_step.dependOn(&b.addRunArtifact(editor_tests).step);
    editor_step.dependOn(&b.addRunArtifact(editor_wire_tests).step);
    const editor_client_tests = b.addTest(.{ .root_module = app.modules.client, .filters = &.{ "queued editor", "queue metadata" } });
    editor_step.dependOn(&b.addRunArtifact(editor_client_tests).step);
    if (app.modules.gui) |gui| {
        const editor_gui_tests = b.addTest(.{ .root_module = gui, .filters = &.{ "editor", "agent file link" } });
        editor_step.dependOn(&b.addRunArtifact(editor_gui_tests).step);
    }

    // Pi and OpenCode load their Telar integration as TypeScript source, so
    // Node runs its tests and drives the built executable's install flows
    // in a throwaway home.
    const integrations_step = b.step("test-integrations", "Run the Pi extension and OpenCode plugin tests, their installation, hook pane identity, CLI help discovery and the limit registry with Node");
    const integration_tests = b.addSystemCommand(&.{ "node", "--test", b.pathFromRoot("src/cli/integration/opencode.test.mjs"), b.pathFromRoot("src/cli/integration/pi.test.mjs") });
    const install_tests = b.addSystemCommand(&.{ "node", b.pathFromRoot("src/cli/integration/install.test.mjs") });
    install_tests.addArtifactArg(app.exe);
    const hook_identity_tests = b.addSystemCommand(&.{ "node", b.pathFromRoot("src/cli/integration/hook_identity.test.mjs") });
    hook_identity_tests.addArtifactArg(app.exe);
    const help_tests = b.addSystemCommand(&.{ "node", b.pathFromRoot("src/cli/integration/help.test.mjs") });
    help_tests.addArtifactArg(app.exe);
    integrations_step.dependOn(&integration_tests.step);
    integrations_step.dependOn(&install_tests.step);
    integrations_step.dependOn(&hook_identity_tests.step);
    integrations_step.dependOn(&help_tests.step);
    const limits_tests = b.addSystemCommand(&.{ "node", b.pathFromRoot("src/cli/integration/limits.test.mjs") });
    limits_tests.addArtifactArg(app.exe);
    integrations_step.dependOn(&limits_tests.step);
    const cli_limits_tests = b.addSystemCommand(&.{ "node", b.pathFromRoot("src/cli/integration/cli_limits.test.mjs") });
    cli_limits_tests.addArtifactArg(app.exe);
    integrations_step.dependOn(&cli_limits_tests.step);
    test_step.dependOn(integrations_step);

    const media_tests = b.addTest(.{ .root_module = app.modules.backend, .filters = &.{"PNG"} });
    b.step("test-png", "Run PNG decoding and pane ingestion tests").dependOn(&b.addRunArtifact(media_tests).step);
    const isolation_tests = b.addTest(.{ .root_module = app.modules.backend, .filters = &.{"performance probe"} });
    const isolation_step = b.step("test-isolation", "Measure bounded search, graphics staging and history query work");
    const isolation_run = b.addRunArtifact(isolation_tests);
    isolation_run.has_side_effects = true;
    isolation_step.dependOn(&isolation_run.step);
    const cache_trace_step = b.step("build-cache-trace", "Build the client hot-path windows traced by the touchrange Valgrind tool");
    if (app.modules.gui) |gui| {
        const gui_cache_trace_tests = b.addTest(.{ .name = "telar-cache-trace-gui", .root_module = gui, .filters = &.{"cache trace"} });
        cache_trace_step.dependOn(&b.addInstallArtifact(gui_cache_trace_tests, .{}).step);
    }
    const transport_test_step = b.step("test-transport", "Run the local transport tests");
    transport_test_step.dependOn(app.modules.libraries.addTestRun(b, "localsocket"));
    const schema_test_step = b.step("test-schema", "Run the shared protocol schema tests");
    // The handshake's own tests, plus the one native fuzz target in its own
    // root so the suites and the coverage build never compile a
    // `std.testing.fuzz` call. `zig build test-handshake --fuzz=10K` fuzzes
    // `decodeClientHello` alone.
    const handshake_step = b.step("test-handshake", "Run the handshake tests; add --fuzz=<limit> to fuzz ClientHello decoding");
    const handshake_source = b.path("src/core/schema/handshake.zig");
    const handshake_tests = b.addTest(.{
        .name = "handshake",
        .root_module = b.createModule(.{
            .root_source_file = handshake_source,
            .target = app.modules.target,
            .optimize = app.modules.optimize,
        }),
    });
    handshake_step.dependOn(&b.addRunArtifact(handshake_tests).step);

    // The test runner skips fuzzing on backends without instrumentation, so
    // LLVM is not left to the host's default. Zig 0.16.0's runner does not
    // compile its fuzz loop with error return traces (test_runner.zig passes
    // a `builtin.StackTrace` to `std.debug.writeStackTrace`), so this one
    // artifact goes without them; runtime safety stays on.
    const handshake_fuzz_module = b.createModule(.{
        .root_source_file = b.path("src/core/schema/handshake_fuzz_test.zig"),
        .target = app.modules.target,
        .optimize = app.modules.optimize,
        .error_tracing = false,
    });
    handshake_fuzz_module.addImport("handshake", b.createModule(.{
        .root_source_file = handshake_source,
        .target = app.modules.target,
        .optimize = app.modules.optimize,
    }));
    const handshake_fuzz_tests = b.addTest(.{
        .name = "handshake-fuzz",
        .root_module = handshake_fuzz_module,
        .use_llvm = true,
    });
    handshake_step.dependOn(&b.addRunArtifact(handshake_fuzz_tests).step);
    fuzz_http1.add(b, app);
    fuzz_frames.add(b, app.modules);
    fuzz_ipc_client.add(b, app.modules);
    fuzz_ipc_server.add(b, app.modules);
    fuzz_http2.add(b, app);
    fuzz_imaging.add(b, app.modules);
    const wire_test_step = b.step("test-wire", "Run wire contracts without PTY integration tests");
    wire_test_step.dependOn(app.modules.libraries.addTestRun(b, "bytecodec"));
    wire_test_step.dependOn(app.modules.libraries.addTestRun(b, "cellcodec"));
    const release_step = b.step(
        "verify-release",
        "Run correctness, portability, and p99 performance gates",
    );
    const release_benchmarks = b.addRunArtifact(bench.benchmarks);
    release_benchmarks.addArgs(&.{ "--samples", "8", "--sample-ms", "20", "--enforce" });
    release_step.dependOn(test_step);
    release_step.dependOn(&release_benchmarks.step);
    release_step.dependOn(&app.install.step);

    const suites = [_]Suite{
        // Only referenced through non-pub imports elsewhere, so their tests
        // never run unless they are their own suite roots.
        .{ .path = "src/core/graphics.zig" },
        .{ .path = "src/core/diagnostics.zig" },
        .{ .path = "src/core/Sink.zig", .libc = true },
        .{ .path = "src/core/DiagnosticLogName.zig" },
        .{ .path = "src/core/ProfileStore.zig", .libc = true },
        .{ .path = "src/core/MachineProfiles.zig" },
        .{ .path = "src/core/schema/handshake.zig", .schema = true },
        .{ .path = "src/core/schema_contract_test.zig", .schema = true },
        .{ .path = "src/core/plugin.zig" },
        .{ .path = "src/client_tests/tests.zig", .libc = true, .client_integration = true },
        .{ .path = "src/backend/proxy_test.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/history/history_tests.zig", .vt = true, .libc = true },
        .{ .path = "src/backend/backend.zig", .vt = true, .libc = true },
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
    for (suites) |suite| {
        const tests = app.modules.addSuiteTest(b, suite);
        app.coverage.instrumentTest(tests);

        check_step.dependOn(&app.modules.addSuiteTest(b, suite).step);

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
        if (suite.schema) {
            wire_test_step.dependOn(&run_tests.step);
        }
        if (std.mem.eql(u8, suite.path, "src/backend/backend.zig")) {
            b.step("test-runtime", "Run backend runtime and provider tests").dependOn(&run_tests.step);
        }
        if (std.mem.eql(u8, suite.path, "src/main.zig")) {
            b.step("test-cli", "Run command-line parser and control tests").dependOn(&run_tests.step);
        }
        if (std.mem.eql(u8, suite.path, "src/core/MachineProfiles.zig")) {
            b.step("test-machine-profiles", "Run the saved machines' file format tests").dependOn(&run_tests.step);
        }

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
        if (suite.client_integration) {
            b.step("test-client-integration", "Run the shared client over a real socket without a window").dependOn(&run_tests.step);
            client_integration_step.dependOn(&run_tests.step);
        }
    }

    // The same drawing code against a width table that answers nonsense, so
    // the module seam is proven rather than asserted. Only this file's tests
    // run: the ones inside `cellgrid` assert real widths and cannot pass here.
    const unicode_fake = b.createModule(.{
        .root_source_file = b.path("lib/unicode/fake.zig"),
        .target = app.modules.target,
        .optimize = app.modules.optimize,
    });
    app.coverage.instrumentModule(unicode_fake);
    const fake_libraries = Libraries.create(b, app.modules.target, app.modules.optimize, &.{.{
        .name = "unicode",
        .module = unicode_fake,
    }}, app.modules.natives);
    const substitution = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/unicode/substitution_test.zig"),
            .target = app.modules.target,
            .optimize = app.modules.optimize,
        }),
        .filters = &.{"injected table"},
    });
    substitution.root_module.addImport("cellgrid", fake_libraries.get("cellgrid"));
    app.coverage.instrumentTest(substitution);
    parallel_test_prerequisites.dependOn(&b.addRunArtifact(substitution).step);

    // Runtime work counters compile only into a root that opts into profile
    // counts, which a test runner never is, so their fixture is a program.
    // It spawns PTY children, so it runs after the parallel suites.
    const work_counters = b.addExecutable(.{
        .name = "runtime-work-counters",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime_work_counters_main.zig"),
            .target = app.modules.target,
            .optimize = app.modules.optimize,
            .link_libc = true,
        }),
    });
    work_counters.root_module.addImport("telar-backend", app.modules.backend);
    work_counters.root_module.addImport("telar-core", app.modules.core);
    work_counters.root_module.addImport("ghostty-vt", app.modules.ghostty_vt);
    app.modules.libraries.addImports(work_counters.root_module);
    const work_counters_run = isolatedTestRun(b, work_counters, parallel_test_prerequisites);
    b.step("test-runtime-work-counters", "Check exact runtime work counts in a profile-counts build").dependOn(&b.addRunArtifact(work_counters).step);
    test_step.dependOn(&work_counters_run.step);

    const check_programs = b.step("check-programs", "Analyze every first-party executable entrypoint");
    for ([_]*std.Build.Step.Compile{ app.exe, bench.benchmarks, bench.echo_probe, work_counters }) |program| {
        const analyzed = b.addExecutable(.{ .name = program.name, .root_module = program.root_module });
        check_programs.dependOn(&analyzed.step);
    }
    check_step.dependOn(check_programs);

    return parallel_test_prerequisites;
}

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

fn argsNamePaths(args: ?[]const []const u8) bool {
    for (args orelse return false) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            return true;
        }
    }

    return false;
}
