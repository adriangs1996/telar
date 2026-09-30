//! The imaging fuzz targets: PNG and ICO decoding, each fuzzed from its own
//! root under `lib/imaging` against the configured `imaging` library, so the
//! same Wuffs module decodes in the fuzzer and in telar. The roots stay out
//! of `test-libraries`, the suites and the coverage build, which compile with
//! `-ffuzz`: Zig 0.16.0's test runner does not compile a `std.testing.fuzz`
//! call in Debug with error return traces, and segfaults on one in an
//! instrumented binary run without `--fuzz`.
//!
//! `--fuzz` rebuilds the whole compilation with `-ffuzz`, which also reaches
//! the Wuffs C that `wuffs_c` compiles. Clang then emits comparison callbacks
//! the Zig 0.16.0 fuzzer does not define, and counters its PC table does not
//! list, so the fuzzer would neither link nor start. The fuzz roots import a
//! copy of the configured library whose `wuffs_c` is built without fuzz
//! instrumentation; the shared modules stay untouched, and the Zig of
//! `imaging` is still instrumented.
const std = @import("std");
const Modules = @import("Modules.zig");

/// A fuzz root and the step that runs it alone.
const FuzzTarget = struct {
    name: []const u8,
    root: []const u8,
    step: []const u8,
    description: []const u8,
};

const targets = [_]FuzzTarget{
    .{
        .name = "imaging-png-fuzz",
        .root = "lib/imaging/png_fuzz_test.zig",
        .step = "test-fuzz-imaging-png",
        .description = "Replay the PNG fuzz corpus; add --fuzz=<limit> to fuzz PNG decoding",
    },
    .{
        .name = "imaging-ico-fuzz",
        .root = "lib/imaging/ico_fuzz_test.zig",
        .step = "test-fuzz-imaging-ico",
        .description = "Replay the ICO fuzz corpus; add --fuzz=<limit> to fuzz ICO decoding",
    },
};

/// Registers `test-fuzz-imaging`, which runs the imaging library tests and
/// both fuzz roots, and one step per root so a campaign fuzzes one artifact.
///
/// ```zig
/// fuzz_imaging.add(b, app.modules);
/// ```
pub fn add(b: *std.Build, modules: Modules) void {
    const step = b.step("test-fuzz-imaging", "Run the imaging tests and replay both fuzz corpora; add --fuzz=<limit> to fuzz PNG and ICO decoding");
    step.dependOn(modules.libraries.addTestRun(b, "imaging"));

    for (targets) |target| {
        const run = &b.addRunArtifact(addFuzzTest(b, modules, target)).step;
        step.dependOn(run);
        b.step(target.step, target.description).dependOn(run);
    }
}

/// The test runner skips fuzzing on backends without instrumentation, so
/// LLVM is not left to the host's default, and only the fuzz root drops error
/// return traces; runtime safety stays on and the library keeps its own
/// settings.
fn addFuzzTest(b: *std.Build, modules: Modules, target: FuzzTarget) *std.Build.Step.Compile {
    const root = b.createModule(.{
        .root_source_file = b.path(target.root),
        .target = modules.target,
        .optimize = modules.optimize,
        .error_tracing = false,
    });
    root.addImport("imaging", uninstrumentedWuffs(b, modules.libraries.get("imaging")));

    return b.addTest(.{
        .name = target.name,
        .root_module = root,
        .use_llvm = true,
    });
}

/// `imaging` over a copy of its `wuffs` whose `wuffs_c` builds without fuzz
/// instrumentation; every other setting is the configured one.
fn uninstrumentedWuffs(b: *std.Build, imaging: *std.Build.Module) *std.Build.Module {
    const wuffs = imaging.import_table.get("wuffs").?;
    const wuffs_c = copyModule(b, wuffs.import_table.get("wuffs_c").?);
    wuffs_c.fuzz = false;

    const wuffs_copy = copyModule(b, wuffs);
    wuffs_copy.addImport("wuffs_c", wuffs_c);

    const imaging_copy = copyModule(b, imaging);
    imaging_copy.addImport("wuffs", wuffs_copy);
    return imaging_copy;
}

/// A module with the same sources, settings and imports as `module`, whose
/// imports and settings change without touching the original. Its graph is
/// computed again from its own import table.
fn copyModule(b: *std.Build, module: *std.Build.Module) *std.Build.Module {
    const copy = b.allocator.create(std.Build.Module) catch @panic("OOM");
    copy.* = module.*;
    copy.import_table = module.import_table.clone(b.allocator) catch @panic("OOM");
    copy.cached_graph = .{
        .modules = &.{},
        .names = &.{},
    };

    return copy;
}
