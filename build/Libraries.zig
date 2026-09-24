//! The standalone libraries under `lib/`. A library imports only `std`,
//! external dependencies and other libraries, never a telar module, so the
//! compiler keeps telar state and policy out of it.
const std = @import("std");
const Coverage = @import("Coverage.zig");
const External = @import("LibraryExternal.zig");
const Libraries = @This();

const Spec = struct {
    /// Module name, directory under `lib/` and the alias consumers import it as.
    name: []const u8,
    /// Libraries listed earlier in `specs`, or externals the caller provides.
    imports: []const []const u8 = &.{},
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
        .name = "pacing",
        .libc = true,
    },
    .{
        .name = "pi_rpc",
    },
    .{
        .name = "pty",
        .libc = true,
        .posix = true,
    },
    // Where column widths come from. The drawing layer names this module,
    // never the emulator behind it, so a build can bind another provider.
    .{
        .name = "unicode",
        .imports = &.{"ghostty-vt"},
    },
    .{
        .name = "cellgrid",
        .imports = &.{"unicode"},
    },
};

modules: [specs.len]*std.Build.Module,
externals: []const External,

/// Builds every library for one target, the way `Application` and the
/// benchmark graph each need their own copy. An external named like a
/// library replaces it, as the portability checks do with the width table.
///
/// ```zig
/// const libraries = Libraries.create(b, target, optimize, &.{.{ .name = "ghostty-vt", .module = ghostty_vt }});
/// ```
pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, externals: []const External) Libraries {
    var self: Libraries = .{
        .modules = undefined,
        .externals = b.allocator.dupe(External, externals) catch @panic("OOM"),
    };

    for (specs, 0..) |spec, index| {
        if (find(externals, spec.name)) |replacement| {
            self.modules[index] = replacement;
            continue;
        }

        const module = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&.{ "lib", spec.name, "root.zig" })),
            .target = target,
            .optimize = optimize,
            .link_libc = spec.libc,
        });
        for (spec.imports) |name| {
            module.addImport(name, find(externals, name) orelse self.built(name, index));
        }

        self.modules[index] = module;
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

/// The library named `name`.
///
/// ```zig
/// const cellgrid = libraries.get("cellgrid");
/// ```
pub fn get(self: Libraries, name: []const u8) *std.Build.Module {
    return self.built(name, specs.len);
}

/// Registers each library's tests under `test-libraries`, `test` and
/// `check`, and fails the build graph if a library imports anything that is
/// not another library or a declared external.
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
/// operating-system branch compiles somewhere. Replaced libraries are skipped.
///
/// ```zig
/// Libraries.create(b, windows, .Debug, externals).addChecks(b, cross_step, windows);
/// ```
pub fn addChecks(self: Libraries, b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget) void {
    for (specs, self.modules) |spec, library| {
        if (spec.posix and target.result.os.tag == .windows) {
            continue;
        }

        if (find(self.externals, spec.name) != null) {
            continue;
        }

        const check = b.addTest(.{
            .name = b.fmt("lib-{s}-{s}-{s}", .{ spec.name, @tagName(target.result.os.tag), @tagName(target.result.cpu.arch) }),
            .root_module = library,
        });
        step.dependOn(&check.step);
    }
}

fn contains(self: Libraries, module: *std.Build.Module) bool {
    for (self.externals) |external| {
        if (external.module == module) {
            return true;
        }
    }

    return std.mem.indexOfScalar(*std.Build.Module, &self.modules, module) != null;
}

/// A library declared before position `limit` in `specs`.
fn built(self: Libraries, name: []const u8, limit: usize) *std.Build.Module {
    for (specs[0..limit], 0..) |spec, index| {
        if (std.mem.eql(u8, spec.name, name)) {
            return self.modules[index];
        }
    }

    std.debug.panic("library {s} is not declared before its importer", .{name});
}

fn find(externals: []const External, name: []const u8) ?*std.Build.Module {
    for (externals) |external| {
        if (std.mem.eql(u8, external.name, name)) {
            return external.module;
        }
    }

    return null;
}
