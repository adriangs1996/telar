//! The HTTP/1 relay's native fuzz targets: head reading and analysis, and
//! body relay. Each target is its own test root under `lib/httprelay/http1/`
//! that imports the `httprelay` library as a module, so no suite and no
//! coverage build compiles a `std.testing.fuzz` call.
//!
//! `test-fuzz-http1` runs the library's tests and both targets' seeds;
//! `test-fuzz-http1-head` and `test-fuzz-http1-body` run one target each, so
//! `--fuzz=<limit>` fuzzes one target at a time instead of both at once.
const std = @import("std");
const Application = @import("Application.zig");

/// One fuzz target: its step suffix, its test root and what it fuzzes.
const Target = struct {
    name: []const u8,
    root: []const u8,
    fuzzes: []const u8,
};

const targets = [_]Target{
    .{
        .name = "head",
        .root = "lib/httprelay/http1/head_fuzz_test.zig",
        .fuzzes = "HTTP/1 head reading and analysis",
    },
    .{
        .name = "body",
        .root = "lib/httprelay/http1/body_fuzz_test.zig",
        .fuzzes = "HTTP/1 body relay",
    },
};

/// Registers `test-fuzz-http1` and one step per target.
///
/// ```zig
/// fuzz_http1.add(b, app);
/// ```
pub fn add(b: *std.Build, app: Application) void {
    const all_step = b.step("test-fuzz-http1", "Run the httprelay tests and HTTP/1 fuzz seeds; add --fuzz=<limit> to fuzz");
    all_step.dependOn(app.modules.libraries.addTestRun(b, "httprelay"));

    for (targets) |target| {
        const run = addTarget(b, app, target);
        const step = b.step(
            b.fmt("test-fuzz-http1-{s}", .{target.name}),
            b.fmt("Run the {s} fuzz seeds; add --fuzz=<limit> to fuzz it alone", .{target.fuzzes}),
        );
        step.dependOn(run);
        all_step.dependOn(run);
    }
}

/// The test runner skips fuzzing on backends without instrumentation, so
/// LLVM is not left to the host's default. Zig 0.16.0's runner does not
/// compile its fuzz loop with error return traces, so only the target's own
/// root goes without them; runtime safety stays on, and the relay keeps the
/// library module every other graph builds.
fn addTarget(b: *std.Build, app: Application, target: Target) *std.Build.Step {
    const module = b.createModule(.{
        .root_source_file = b.path(target.root),
        .target = app.modules.target,
        .optimize = app.modules.optimize,
        .error_tracing = false,
    });
    module.addImport("httprelay", app.modules.libraries.get("httprelay"));

    const tests = b.addTest(.{
        .name = b.fmt("http1-{s}-fuzz", .{target.name}),
        .root_module = module,
        .use_llvm = true,
    });
    return &b.addRunArtifact(tests).step;
}
