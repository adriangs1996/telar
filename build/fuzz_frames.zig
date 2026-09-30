//! Native fuzz targets for the three layers of a pane frame: the frame body,
//! the cell runs inside its spans and the text metadata it carries.
//!
//! Each target is its own test root, so the suites and the coverage build
//! never compile its `std.testing.fuzz` calls, and only its executable drops
//! error return traces, which Zig 0.16.0's fuzz loop cannot compile; runtime
//! safety stays on. `zig build test-fuzz-frames` replays every seed corpus.
//! One target per step keeps a `--fuzz=<limit>` campaign to one executable:
//!
//! ```sh
//! zig build test-fuzz-frames-body --fuzz=10K
//! ```
const std = @import("std");
const Libraries = @import("Libraries.zig");
const Modules = @import("Modules.zig");

/// The frame body target is rooted at `src/core/frame_fuzz_root.zig`: a module
/// cannot import above the directory of its root file, and
/// `frame_support.zig` imports `../text_metadata`.
const frame_body_libraries: []const []const u8 = &.{ "bytecodec", "cellcodec", "cellgrid", "keyinput", "localsocket" };
const cell_libraries: []const []const u8 = &.{ "bytecodec", "cellcodec", "cellgrid" };
const metadata_libraries: []const []const u8 = &.{"bytecodec"};

/// Registers `test-fuzz-frames` and one step per target.
///
/// ```zig
/// fuzz_frames.add(b, app.modules);
/// ```
pub fn add(b: *std.Build, modules: Modules) void {
    const libraries = fuzzLibraries(b, modules);
    const all_step = b.step("test-fuzz-frames", "Replay the frame body, cell run and text metadata fuzz corpora; add --fuzz=<limit> to fuzz them");

    const body_tests = addTarget(b, modules, "frame-body-fuzz", "src/core/frame_fuzz_root.zig");
    libraries.addSelectedImports(body_tests.root_module, frame_body_libraries);
    addRun(b, all_step, body_tests, "test-fuzz-frames-body");

    const cell_tests = addTarget(b, modules, "cell-run-fuzz", "lib/cellcodec/cell_run_fuzz_test.zig");
    libraries.addSelectedImports(cell_tests.root_module, cell_libraries);
    addRun(b, all_step, cell_tests, "test-fuzz-frames-cells");

    const metadata_tests = addTarget(b, modules, "text-metadata-fuzz", "src/core/text_metadata/metadata_fuzz_test.zig");
    libraries.addSelectedImports(metadata_tests.root_module, metadata_libraries);
    addRun(b, all_step, metadata_tests, "test-fuzz-frames-metadata");
}

/// The test runner skips fuzzing on backends without instrumentation, so
/// LLVM is not left to the host's default.
fn addTarget(b: *std.Build, modules: Modules, name: []const u8, root: []const u8) *std.Build.Step.Compile {
    return b.addTest(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = modules.target,
            .optimize = modules.optimize,
            .error_tracing = false,
        }),
        .use_llvm = true,
    });
}

/// `cellgrid` names the `unicode` library, whose provider links the
/// emulator's C++ width tables. Built with `--fuzz`, those objects call
/// `__sanitizer_cov_trace_cmp*` hooks Zig's fuzzer does not define, and the
/// link fails. No target measures a grapheme, so they bind the fake width
/// table the portability checks use, as their own copy of the libraries.
fn fuzzLibraries(b: *std.Build, modules: Modules) Libraries {
    const unicode = b.createModule(.{
        .root_source_file = b.path("lib/unicode/fake.zig"),
        .target = modules.target,
        .optimize = modules.optimize,
    });
    return Libraries.create(
        b,
        modules.target,
        modules.optimize,
        &.{
            .{
                .name = "unicode",
                .module = unicode,
            },
        },
        modules.natives,
    );
}

fn addRun(b: *std.Build, all_step: *std.Build.Step, tests: *std.Build.Step.Compile, step_name: []const u8) void {
    const run = b.addRunArtifact(tests);
    all_step.dependOn(&run.step);
    b.step(step_name, b.fmt("Replay the {s} corpus; add --fuzz=<limit> to fuzz it alone", .{tests.name})).dependOn(&run.step);
}
