//! The native fuzz target for `decodeClient`, in its own test root so the
//! suites and the coverage build never compile its `std.testing.fuzz` call.

const std = @import("std");
const Modules = @import("Modules.zig");
const Libraries = @import("Libraries.zig");

/// The libraries `decodeClient` and its encoders reach through `telar-core`.
const core_libraries = [_][]const u8{ "bytecodec", "localsocket", "cellcodec" };

/// Registers `test-fuzz-ipc-client`, which replays the client message corpus
/// and runs the decoder's deterministic budget tests; with `--fuzz=<limit>`
/// it fuzzes `decodeClient`.
///
/// `--fuzz` instruments C sources with sanitizer coverage callbacks that
/// Zig 0.16.0's fuzzer does not define, so the target cannot link the shared
/// `telar-core`, whose libraries bring the emulator's C++, FreeType and
/// Wuffs. It builds its own `core.zig` over the pure libraries above, with
/// the fake width table the cross checks use standing in for `unicode`: no
/// client message lays out text. The test runner skips fuzzing on backends
/// without instrumentation, so LLVM is not left to the host's default, and
/// its fuzz loop does not compile with error return traces, so this one
/// artifact goes without them; runtime safety stays on.
///
/// ```zig
/// fuzz_ipc_client.add(b, app.modules);
/// ```
pub fn add(b: *std.Build, modules: Modules) void {
    const step = b.step(
        "test-fuzz-ipc-client",
        "Replay the client message fuzz corpus; add --fuzz=<limit> to fuzz decodeClient",
    );
    const unicode = b.createModule(.{
        .root_source_file = b.path("lib/unicode/fake.zig"),
        .target = modules.target,
        .optimize = modules.optimize,
    });
    const libraries = Libraries.create(
        b,
        modules.target,
        modules.optimize,
        &.{.{
            .name = "unicode",
            .module = unicode,
        }},
        modules.natives,
    );

    const core = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = modules.target,
        .optimize = modules.optimize,
    });
    for (core_libraries) |name| {
        core.addImport(name, libraries.get(name));
    }

    const module = b.createModule(.{
        .root_source_file = b.path("src/core/schema/messages/client_fuzz_test.zig"),
        .target = modules.target,
        .optimize = modules.optimize,
        .error_tracing = false,
    });
    module.addImport("telar-core", core);
    module.addImport("bytecodec", libraries.get("bytecodec"));

    const tests = b.addTest(.{
        .name = "ipc-client-fuzz",
        .root_module = module,
        .use_llvm = true,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}
