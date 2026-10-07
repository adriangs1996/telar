const std = @import("std");
const Application = @import("Application.zig");
const Benchmarks = @import("Benchmarks.zig");
const model_build = @import("model.zig");

const source_roots: []const []const u8 = &.{ "build.zig", "build", "lib", "src", "examples", "benchmarks", "linters" };

/// Register source checks and release gates: `checks.add(b, app, bench, cross_step)`.
pub fn add(b: *std.Build, app: Application, bench: Benchmarks, cross_step: *std.Build.Step) void {
    // ZLS uses "check" on save. Source validators run without building tests.
    const check_step = b.step("check", "Validate source organization and analyze every program");
    const model_boundaries = b.addSystemCommand(&.{
        "python3",
        b.pathFromRoot("tools/check_model_boundaries.py"),
        "--root",
        b.pathFromRoot("."),
    });
    model_boundaries.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    b.step("check-model-boundaries", "Check shared model dependency boundaries").dependOn(&model_boundaries.step);
    check_step.dependOn(&model_boundaries.step);

    const client_boundaries = b.addSystemCommand(&.{ "python3", b.pathFromRoot("tools/check_client_boundaries.py"), "--root", b.pathFromRoot("src/client") });
    client_boundaries.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    client_boundaries.step.dependOn(&model_boundaries.step);
    b.step("check-client-boundaries", "Check shared-client module boundaries").dependOn(&client_boundaries.step);
    check_step.dependOn(&client_boundaries.step);

    const reexports = b.addSystemCommand(&.{ "python3", b.pathFromRoot("tools/check_library_reexports.py"), "--root", b.pathFromRoot(".") });
    reexports.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    b.step("check-library-reexports", "Check that packages import libraries instead of re-exporting them").dependOn(&reexports.step);
    check_step.dependOn(&reexports.step);

    // The shared client depends on model, core, the Lua modules and the
    // libraries; the checker in tools/ enforces the same set at source level.
    app.modules.libraries.checkImports();
    var library_count: usize = 0;
    for (app.modules.libraries.modules) |library| {
        if (library != null) {
            library_count += 1;
        }
    }

    std.debug.assert(app.modules.client.import_table.count() == 4 + library_count and app.modules.client.import_table.get("telar-core").? == app.modules.core);
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

    const check_programs = b.step("check-programs", "Analyze every first-party executable entrypoint");
    for ([_]*std.Build.Step.Compile{ app.exe, bench.benchmarks, bench.echo_probe }) |program| {
        const analyzed = b.addExecutable(.{ .name = program.name, .root_module = program.root_module });
        check_programs.dependOn(&analyzed.step);
    }
    check_step.dependOn(check_programs);

    const release_step = b.step(
        "verify-release",
        "Run portability and p99 performance gates",
    );
    const release_benchmarks = b.addRunArtifact(bench.benchmarks);
    release_benchmarks.addArgs(&.{ "--samples", "8", "--sample-ms", "20", "--enforce" });
    release_step.dependOn(&release_benchmarks.step);
    release_step.dependOn(&app.install.step);
    release_step.dependOn(cross_step);
}

fn argsNamePaths(args: ?[]const []const u8) bool {
    for (args orelse return false) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            return true;
        }
    }

    return false;
}
