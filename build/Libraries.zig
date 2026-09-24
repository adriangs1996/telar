//! The standalone libraries under `lib/`. A library imports only `std`,
//! external dependencies and other libraries, never a telar module, so the
//! compiler keeps telar state and policy out of it.
const std = @import("std");
const Coverage = @import("Coverage.zig");
const Libraries = @This();

const Spec = struct {
    /// Module name, directory under `lib/` and the alias consumers import it as.
    name: []const u8,
    libc: bool = false,
    /// Built only for POSIX targets.
    posix: bool = false,
};

const specs = [_]Spec{
    .{
        .name = "animate",
    },
    .{
        .name = "console",
        .libc = true,
    },
    .{
        .name = "gfx",
    },
    .{
        .name = "mailbox",
    },
    .{
        .name = "pi_rpc",
    },
    .{
        .name = "pty",
        .libc = true,
        .posix = true,
    },
};

modules: [specs.len]*std.Build.Module,

/// Builds every library for one target, the way `Application` and the
/// benchmark graph each need their own copy.
///
/// ```zig
/// const libraries = Libraries.create(b, target, optimize);
/// ```
pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Libraries {
    var self: Libraries = undefined;
    for (specs, &self.modules) |spec, *module| {
        module.* = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&.{ "lib", spec.name, "root.zig" })),
            .target = target,
            .optimize = optimize,
            .link_libc = spec.libc,
        });
    }

    return self;
}

/// Makes every library importable from `module`.
///
/// ```zig
/// libraries.addImports(backend);
/// ```
pub fn addImports(self: Libraries, module: *std.Build.Module) void {
    for (specs, self.modules) |spec, library| {
        module.addImport(spec.name, library);
    }
}

/// Whether `module` is one of these libraries.
///
/// ```zig
/// std.debug.assert(libraries.contains(dependency));
/// ```
pub fn contains(self: Libraries, module: *std.Build.Module) bool {
    return std.mem.indexOfScalar(*std.Build.Module, &self.modules, module) != null;
}

/// Registers each library's tests under `test-libraries`, `test` and
/// `check`, and fails the build graph if a library imports anything that is
/// not another library.
///
/// ```zig
/// const runs = libraries.addTests(b, coverage, check_step);
/// test_step.dependOn(runs);
/// ```
pub fn addTests(self: Libraries, b: *std.Build, coverage: Coverage, check_step: *std.Build.Step) *std.Build.Step {
    const step = b.step("test-libraries", "Run the standalone library tests");
    for (specs, self.modules) |spec, library| {
        for (library.import_table.values()) |dependency| {
            if (!self.contains(dependency)) {
                std.debug.panic("library {s} imports a module outside lib/", .{spec.name});
            }
        }

        const tests = b.addTest(.{
            .name = b.fmt("lib-{s}", .{spec.name}),
            .root_module = library,
        });
        coverage.instrumentTest(tests);
        check_step.dependOn(&tests.step);
        step.dependOn(&b.addRunArtifact(tests).step);
    }

    return step;
}

/// Analyzes every library that supports `target`, tests included, so each
/// operating-system branch compiles somewhere.
///
/// ```zig
/// Libraries.create(b, windows, .Debug).addChecks(b, cross_step, windows);
/// ```
pub fn addChecks(self: Libraries, b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget) void {
    for (specs, self.modules) |spec, library| {
        if (spec.posix and target.result.os.tag == .windows) {
            continue;
        }

        const check = b.addTest(.{
            .name = b.fmt("lib-{s}-{s}-{s}", .{ spec.name, @tagName(target.result.os.tag), @tagName(target.result.cpu.arch) }),
            .root_module = library,
        });
        step.dependOn(&check.step);
    }
}
