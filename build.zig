const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ghostty_vt = b.dependency("ghostty_vt", .{
        .target = target,
        .optimize = optimize,
    }).module("ghostty-vt");

    // The width tables, behind a module name so the drawing layer never names
    // its provider. Everything that draws imports `unicode`; only this line
    // decides which implementation answers, which is what keeps the drawing
    // core liftable into a build with no emulator in it.
    const unicode = b.createModule(.{
        .root_source_file = b.path("src/unicode.zig"),
        .target = target,
        .optimize = optimize,
    });
    unicode.addImport("ghostty-vt", ghostty_vt);

    // The library itself, so the example consumes it the way anybody else
    // would - which is the cheapest test there is of whether the public API is
    // usable from outside.
    const telar = b.addModule("telar", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    telar.addImport("ghostty-vt", ghostty_vt);
    telar.addImport("unicode", unicode);

    // ---------------------------------------------------------------------
    // The example
    // ---------------------------------------------------------------------

    const sidebar = b.addExecutable(.{
        .name = "sidebar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/sidebar.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    sidebar.root_module.addImport("telar", telar);
    b.installArtifact(sidebar);

    const run_sidebar = b.addRunArtifact(sidebar);
    run_sidebar.step.dependOn(b.getInstallStep());
    b.step("sidebar", "Run the example").dependOn(&run_sidebar.step);

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    const test_step = b.step("test", "Run the tests");

    const Suite = struct {
        path: []const u8,
        vt: bool = false,
        libc: bool = false,
    };
    const suites = [_]Suite{
        .{ .path = "src/ui.zig" },
        .{ .path = "src/term.zig", .libc = true },
        .{ .path = "src/pace.zig" },
        .{ .path = "src/edit.zig" },
        .{ .path = "src/select.zig" },
        .{ .path = "src/blit.zig", .vt = true, .libc = true },
        .{ .path = "examples/sidebar.zig", .vt = true, .libc = true },
    };
    for (suites) |suite| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(suite.path),
                .target = target,
                .optimize = optimize,
                .link_libc = suite.libc,
            }),
        });
        tests.root_module.addImport("unicode", unicode);
        tests.root_module.addImport("telar", telar);
        if (suite.vt) tests.root_module.addImport("ghostty-vt", ghostty_vt);
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // The same drawing code against a width table that answers nonsense, so
    // the module seam is proven rather than asserted. Only this file's tests
    // run: the ones inside `ui.zig` assert real widths and cannot pass here.
    const unicode_fake = b.createModule(.{
        .root_source_file = b.path("src/unicode_fake.zig"),
        .target = target,
        .optimize = optimize,
    });
    const substitution = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unicode_substitution_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"injected table"},
    });
    substitution.root_module.addImport("unicode", unicode_fake);
    test_step.dependOn(&b.addRunArtifact(substitution).step);

    // ---------------------------------------------------------------------
    // Other targets
    // ---------------------------------------------------------------------

    // Type-checks the platform files for targets this machine is not. A Windows
    // implementation that silently stopped compiling would otherwise be
    // invisible until somebody on Windows tried to build - which, for a project
    // developed on one machine, means until a user reports it.
    const cross_step = b.step("cross", "Type-check the platform files elsewhere");
    for ([_]std.Target.Query{
        .{ .os_tag = .windows, .cpu_arch = .x86_64 },
        .{ .os_tag = .linux, .cpu_arch = .x86_64, .abi = .gnu },
    }) |query| {
        const check = b.addObject(.{
            .name = b.fmt("platform-{s}", .{@tagName(query.os_tag.?)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/platform.zig"),
                .target = b.resolveTargetQuery(query),
                .optimize = .Debug,
            }),
        });
        cross_step.dependOn(&check.step);
    }
    test_step.dependOn(cross_step);
}
