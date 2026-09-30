//! The native fuzz target for server IPC decoding, in its own root so the
//! suites and the coverage build never compile its `std.testing.fuzz` call.
const std = @import("std");
const Modules = @import("Modules.zig");
const Libraries = @import("Libraries.zig");

/// The libraries `src/core` imports.
const core_libraries = [_][]const u8{ "bytecodec", "cellcodec", "cellgrid", "keyinput", "kitty_protocol", "localsocket" };

/// Registers `test-fuzz-ipc-server`, which replays the seeds of
/// `server_fuzz_test.zig` and, with `--fuzz=<limit>`, fuzzes `decodeServer`
/// and `decodeServerInto`. The step exists once a caller wires it in.
///
/// ```zig
/// fuzz_ipc_server.add(b, app.modules);
/// ```
pub fn add(b: *std.Build, modules: Modules) void {
    const step = b.step("test-fuzz-ipc-server", "Replay the server IPC fuzz seeds; add --fuzz=<limit> to fuzz server decoding");

    // `--fuzz` instruments every C and C++ object of the executable, and Zig
    // 0.16.0's fuzzer neither defines their comparison callbacks nor accepts
    // their counters (it aborts on a PC table of another length). The
    // application's core reaches C++ only through `unicode`, which binds the
    // emulator, so this target builds its own core against the libraries
    // with `unicode` bound to `lib/unicode/fake.zig`, as the substitution
    // test does. Decoding never asks for a width: only cellgrid's buffer
    // writes and text layout do.
    const unicode_fake = b.createModule(.{
        .root_source_file = b.path("lib/unicode/fake.zig"),
        .target = modules.target,
        .optimize = modules.optimize,
    });
    const libraries = Libraries.create(
        b,
        modules.target,
        modules.optimize,
        &.{
            .{
                .name = "unicode",
                .module = unicode_fake,
            },
        },
        modules.natives,
    );
    const core = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = modules.target,
        .optimize = modules.optimize,
    });
    libraries.addSelectedImports(core, &core_libraries);

    // As for the handshake target: LLVM is chosen explicitly because the test
    // runner skips fuzzing without instrumentation, and only this root goes
    // without error return traces, which Zig 0.16.0's fuzz loop cannot
    // compile. Runtime safety stays on.
    const module = b.createModule(.{
        .root_source_file = b.path("src/core/schema/messages/server_fuzz_test.zig"),
        .target = modules.target,
        .optimize = modules.optimize,
        .error_tracing = false,
    });
    module.addImport("telar-core", core);

    const tests = b.addTest(.{
        .name = "ipc-server-fuzz",
        .root_module = module,
        .use_llvm = true,
    });
    step.dependOn(&b.addRunArtifact(tests).step);
}
