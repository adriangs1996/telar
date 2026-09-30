//! Native fuzz targets for the HTTP/2 frame reader and header observer.
//!
//! Each target is its own test root, importing its library as a module the
//! way `handshake_fuzz_test.zig` imports the handshake, so no ordinary suite
//! and no `-ffuzz` coverage build compiles a `std.testing.fuzz` call.
//! `build/tests.zig` registers the steps; see docs/testing/fuzz-http2.md.
const std = @import("std");
const Application = @import("Application.zig");

/// A fuzz root and the library it exercises through its public surface.
const FuzzTarget = struct {
    name: []const u8,
    step: []const u8,
    description: []const u8,
    root: []const u8,
    library: []const u8,
};

const targets = [_]FuzzTarget{
    .{
        .name = "h2frames-reader-fuzz",
        .step = "test-fuzz-http2-reader",
        .description = "Fuzz the HTTP/2 frame reader alone; add --fuzz=<limit>",
        .root = "lib/h2frames/reader_fuzz_test.zig",
        .library = "h2frames",
    },
    .{
        .name = "httprelay-http2-observer-fuzz",
        .step = "test-fuzz-http2-observer",
        .description = "Fuzz the HTTP/2 header observer alone; add --fuzz=<limit>",
        .root = "lib/httprelay/http2/observer_fuzz_test.zig",
        .library = "httprelay",
    },
};

/// Registers `test-fuzz-http2`, which runs the h2frames and httprelay tests
/// and both fuzz roots, and one step per fuzz root so campaigns run one at a
/// time.
///
/// ```zig
/// fuzz_http2.add(b, app);
/// ```
pub fn add(b: *std.Build, app: Application) void {
    const step = b.step("test-fuzz-http2", "Run the HTTP/2 reader and observer tests; add --fuzz=<limit> to fuzz both");
    const libraries = app.modules.libraries;

    step.dependOn(libraries.addTestRun(b, "h2frames"));
    step.dependOn(libraries.addTestRun(b, "httprelay"));

    for (targets) |target| {
        const run = &b.addRunArtifact(fuzzTest(b, app, target)).step;
        step.dependOn(run);
        b.step(target.step, target.description).dependOn(run);
    }
}

/// Zig 0.16.0's runner does not compile its fuzz loop with error return
/// traces, so only this artifact goes without them; runtime safety stays on,
/// and LLVM is chosen because the runner skips fuzzing without it.
fn fuzzTest(b: *std.Build, app: Application, target: FuzzTarget) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(target.root),
        .target = app.modules.target,
        .optimize = app.modules.optimize,
        .error_tracing = false,
    });
    module.addImport(target.library, app.modules.libraries.get(target.library));

    return b.addTest(.{
        .name = target.name,
        .root_module = module,
        .use_llvm = true,
    });
}
