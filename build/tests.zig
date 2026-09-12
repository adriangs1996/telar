const std = @import("std");
const Application = @import("Application.zig");
const Benchmarks = @import("Benchmarks.zig");
const Suite = @import("Suite.zig");

const source_roots: []const []const u8 = &.{ "build.zig", "build", "src", "examples", "benchmarks", "test", "linters" };

/// Register tests/checks and return the parallel-test barrier: `tests.add(b, app, bench)`.
pub fn add(b: *std.Build, app: Application, bench: Benchmarks) *std.Build.Step {
    const test_step = b.step("test", "Run the tests");
    const client_tests = b.addTest(.{ .root_module = app.modules.client });
    app.coverage.instrumentTest(client_tests);
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
    const client_check = b.addTest(.{ .root_module = app.modules.client });
    check_step.dependOn(&client_check.step);
    check_step.dependOn(&client_boundaries.step);
    const check_client = b.step("check-client", "Semantic-analyze only the shared client");
    check_client.dependOn(&client_check.step);
    check_client.dependOn(&client_boundaries.step);
    // The shared client depends on core and the Lua modules only; the checker
    // in tools/ enforces the same set at source level.
    std.debug.assert(app.modules.client.import_table.count() == 3 and app.modules.client.import_table.get("telar-core").? == app.modules.core);
    std.debug.assert(app.modules.client.import_table.get("telar-lua").? == app.modules.telar_lua and app.modules.client.import_table.get("lua-api").? == app.modules.lua_api);

    for (app.modules.core.import_table.values()) |dependency| {
        std.debug.assert(dependency != app.modules.client and dependency != app.modules.frontend and dependency != app.modules.backend);
    }

    for (app.modules.backend.import_table.values()) |dependency| {
        std.debug.assert(dependency != app.modules.client and dependency != app.modules.frontend);
    }

    for (app.modules.frontend.import_table.values()) |dependency| {
        std.debug.assert(dependency != app.modules.backend);
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
        "Run the runtime observation proxy tests",
    );
    const media_tests = b.addTest(.{ .root_module = app.modules.backend, .filters = &.{"PNG"} });
    b.step("test-png", "Run PNG decoding and pane ingestion tests").dependOn(&b.addRunArtifact(media_tests).step);
    const isolation_tests = b.addTest(.{ .root_module = app.modules.backend, .filters = &.{"performance probe"} });
    const isolation_step = b.step("test-isolation", "Measure bounded search, graphics staging and history query work");
    const isolation_run = b.addRunArtifact(isolation_tests);
    isolation_run.has_side_effects = true;
    isolation_step.dependOn(&isolation_run.step);
    const compression_tests = b.addTest(.{ .root_module = app.modules.frontend, .filters = &.{"performance probe"} });
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
    const release_benchmarks = b.addRunArtifact(bench.benchmarks);
    release_benchmarks.addArgs(&.{ "--samples", "8", "--sample-ms", "20", "--enforce" });
    release_step.dependOn(test_step);
    release_step.dependOn(&release_benchmarks.step);
    release_step.dependOn(&app.install.step);

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
        .target = app.modules.target,
        .optimize = app.modules.optimize,
    });
    app.coverage.instrumentModule(unicode_fake);
    const substitution = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/unicode_substitution_test.zig"),
            .target = app.modules.target,
            .optimize = app.modules.optimize,
        }),
        .filters = &.{"injected table"},
    });
    substitution.root_module.addImport("unicode", unicode_fake);
    app.coverage.instrumentTest(substitution);
    parallel_test_prerequisites.dependOn(&b.addRunArtifact(substitution).step);

    const check_programs = b.step("check-programs", "Analyze every first-party executable entrypoint");
    for ([_]*std.Build.Step.Compile{ app.exe, bench.benchmarks, bench.echo_probe }) |program| {
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
