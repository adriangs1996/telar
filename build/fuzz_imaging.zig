//! The imaging fuzz targets: PNG and ICO decoding, each fuzzed from its own
//! root under `lib/imaging` against a copy of the configured `imaging`
//! library, so the same sources and Wuffs build decode in the fuzzer and in
//! telar. The roots stay out of `test-libraries`, the suites and the
//! coverage build, and are built like the handshake fuzz target of commit
//! d519fb1d, whose message records why.
//!
//! `--fuzz` rebuilds the whole compilation with `-ffuzz`, which also reaches
//! the Wuffs C that `wuffs_c` compiles. Clang then emits comparison callbacks
//! the Zig 0.16.0 fuzzer does not define, and counters its PC table does not
//! list, so the fuzzer would neither link nor start. The fuzz roots import a
//! copy of the configured library whose `wuffs_c` is built without fuzz
//! instrumentation; the shared modules stay untouched, and the Zig of
//! `imaging` is still instrumented under `--fuzz`.
//!
//! `-Dcoverage` sets `fuzz` on every shared library module and, through
//! `Libraries.addTests`, links the zcov runtime object into it. The copy of
//! `imaging` drops only the inherited `fuzz`; it still shares the runtime
//! link object. A flag check with a placeholder runtime path shows no
//! `-ffuzz` on the fuzz roots' compile command, but these steps have not run
//! under `-Dcoverage` with a real runtime: run them without it.
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
        const tests = addFuzzTest(
            b,
            modules,
            target,
        );
        const run = &b.addRunArtifact(tests).step;
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
    root.addImport("imaging", fuzzImaging(b, modules.libraries.get("imaging")));

    return b.addTest(.{
        .name = target.name,
        .root_module = root,
        .use_llvm = true,
    });
}

/// `imaging` over a copy of its `wuffs` whose `wuffs_c` builds without fuzz
/// instrumentation. The `imaging` copy inherits `fuzz` from the root instead
/// of the setting `-Dcoverage` gives the shared module; every other setting
/// is the configured one.
fn fuzzImaging(b: *std.Build, imaging: *std.Build.Module) *std.Build.Module {
    const wuffs = imaging.import_table.get("wuffs").?;
    const wuffs_c = copyModule(b, wuffs.import_table.get("wuffs_c").?);
    wuffs_c.fuzz = false;

    const wuffs_copy = copyModule(b, wuffs);
    wuffs_copy.addImport("wuffs_c", wuffs_c);

    const imaging_copy = copyModule(b, imaging);
    imaging_copy.fuzz = null;
    imaging_copy.addImport("wuffs", wuffs_copy);
    return imaging_copy;
}

/// A module with the same sources, settings and imports as `module`, whose
/// import table and settings change without touching the original. The
/// copy owns its import table and computes its graph again from it.
///
/// Every other list and map of `std.Build.Module` (`c_macros`,
/// `include_dirs`, `lib_paths`, `rpaths`, `frameworks`, `link_objects`) is
/// shared with the original. That is safe only because both are already
/// configured when the registry runs from `tests.add`, and nothing appends
/// to either afterwards; a later `addCSourceFile`, `addIncludePath` or
/// `linkFramework` on either could reallocate storage the other still
/// points to. The graph reset writes the value `Module` declares as the
/// field's default.
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
