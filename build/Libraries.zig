//! The standalone libraries under `lib/`. A library imports only `std`,
//! external dependencies and other libraries, never a telar module, so the
//! compiler keeps telar state and policy out of it.
const std = @import("std");
const Coverage = @import("Coverage.zig");
const External = @import("LibraryExternal.zig");
const Prefix = @import("LibraryPrefix.zig");
const Libraries = @This();

/// Imports a spec may declare.
const max_imports = 4;

const Spec = struct {
    /// Module name, directory under `lib/` and the alias consumers import it as.
    name: []const u8,
    /// Libraries listed earlier in `specs`, or externals the caller provides.
    /// A library whose external is not provided is left out of that graph.
    imports: []const []const u8 = &.{},
    libc: bool = false,
    /// Built only for POSIX targets.
    posix: bool = false,
    system_libraries: []const []const u8 = &.{},
    /// Frameworks linked when the target is macOS.
    macos_frameworks: []const []const u8 = &.{},
    /// Links its system libraries only for the host; other targets can still
    /// analyze packages that import it, and portability checks skip it.
    host_only: bool = false,
};

const specs = [_]Spec{
    .{
        .name = "vtscan",
    },
    .{
        .name = "animate",
    },
    .{
        .name = "gfx",
    },
    .{
        .name = "jsonl",
        .libc = true,
    },
    .{
        .name = "localsocket",
        .libc = true,
        .posix = true,
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
    .{
        .name = "sqlite",
        .libc = true,
        .system_libraries = &.{"sqlite3"},
        .host_only = true,
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
    .{
        .name = "editorremote",
        .libc = true,
        .posix = true,
    },
    .{
        .name = "h2frames",
    },
    .{
        .name = "localca",
        .imports = &.{"tls"},
        .libc = true,
    },
    .{
        .name = "kitty_protocol",
    },
    .{
        .name = "keyinput",
        .imports = &.{"cellgrid"},
    },
    .{
        .name = "textfield",
        .imports = &.{"cellgrid"},
    },
    .{
        .name = "console",
        .imports = &.{ "cellgrid", "keyinput" },
        .libc = true,
    },
    .{
        .name = "textraster",
        .imports = &.{"freetype"},
        .libc = true,
    },
    .{
        .name = "cellglyphs",
        .imports = &.{"gfx"},
    },
    .{
        .name = "urlscan",
    },
    .{
        .name = "fuzzymatch",
    },
    .{
        .name = "syntaxhl",
    },
    .{
        .name = "mdinline",
        .imports = &.{"urlscan"},
    },
    .{
        .name = "bytecodec",
    },
    .{
        .name = "cellcodec",
        .imports = &.{ "cellgrid", "bytecodec" },
    },
    .{
        .name = "dropqueue",
    },
    .{
        .name = "exchangecapture",
        .libc = true,
        .system_libraries = &.{"brotlidec"},
    },
    .{
        .name = "httprelay",
        .imports = &.{ "localca", "h2frames" },
        .libc = true,
        .system_libraries = &.{"nghttp2"},
    },
    .{
        .name = "gitstatus",
    },
    .{
        .name = "hostmetrics",
        .libc = true,
        .macos_frameworks = &.{ "IOKit", "CoreFoundation" },
    },
    .{
        .name = "vtgrid",
        .imports = &.{ "ghostty-vt", "cellgrid", "cellcodec" },
    },
    .{
        .name = "cmdcapture",
        .imports = &.{ "ghostty-vt", "vtscan" },
    },
    .{
        .name = "agentfiles",
        .imports = &.{"sqlite"},
        .host_only = true,
    },
    .{
        .name = "imaging",
        .imports = &.{"wuffs"},
    },
    .{
        .name = "mermaid",
        .libc = true,
        .posix = true,
    },
    .{
        .name = "touchtrace",
    },
    .{
        .name = "privatefile",
        .posix = true,
    },
};

/// Null for a library whose external dependency this graph does not provide.
modules: [specs.len]?*std.Build.Module,
externals: []const External,

/// Builds every library for one target, the way `Application` and the
/// benchmark graph each need their own copy. An external named like a
/// library replaces it, as the portability checks do with the width table.
///
/// ```zig
/// const libraries = Libraries.create(b, target, optimize, &.{.{ .name = "ghostty-vt", .module = ghostty_vt }}, &.{});
/// ```
pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, externals: []const External, prefixes: []const Prefix) Libraries {
    var self: Libraries = .{
        .modules = undefined,
        .externals = b.allocator.dupe(External, externals) catch @panic("OOM"),
    };

    for (specs, 0..) |spec, index| {
        if (find(externals, spec.name)) |replacement| {
            self.modules[index] = replacement;
            continue;
        }

        self.modules[index] = null;
        var dependencies: [max_imports]*std.Build.Module = undefined;
        for (spec.imports, 0..) |name, position| {
            dependencies[position] = find(externals, name) orelse self.declared(name, index) orelse break;
        } else {
            self.modules[index] = build(b, spec, target, optimize, dependencies[0..spec.imports.len]);
            addPrefixes(b, self.modules[index].?, spec, prefixes);
        }
    }

    return self;
}

fn build(b: *std.Build, spec: Spec, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, dependencies: []const *std.Build.Module) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(b.pathJoin(&.{ "lib", spec.name, "root.zig" })),
        .target = target,
        .optimize = optimize,
        .link_libc = spec.libc,
    });
    for (spec.imports, dependencies) |name, dependency| {
        module.addImport(name, dependency);
    }

    if (!spec.host_only or target.query.isNative()) {
        for (spec.system_libraries) |name| {
            module.linkSystemLibrary(name, .{});
        }
    }
    if (target.result.os.tag == .macos) {
        for (spec.macos_frameworks) |name| {
            module.linkFramework(name, .{});
        }
    }

    return module;
}

/// Makes every library importable from `module`.
///
/// ```zig
/// libraries.addImports(backend);
/// ```
pub fn addImports(self: Libraries, module: *std.Build.Module) void {
    for (specs, self.modules) |spec, library| {
        if (library) |available| {
            module.addImport(spec.name, available);
        }
    }
}

/// Makes only the named libraries importable from `module`, for a package
/// whose boundary admits a few pure ones.
///
/// ```zig
/// libraries.addSelectedImports(data, &.{ "cellgrid", "pacing" });
/// ```
pub fn addSelectedImports(self: Libraries, module: *std.Build.Module, names: []const []const u8) void {
    for (names) |name| {
        module.addImport(name, self.get(name));
    }
}

/// The library named `name`.
///
/// ```zig
/// const cellgrid = libraries.get("cellgrid");
/// ```
pub fn get(self: Libraries, name: []const u8) *std.Build.Module {
    return self.declared(name, specs.len) orelse std.debug.panic("library {s} is not built in this graph", .{name});
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
    for (specs, self.modules) |spec, maybe_library| {
        const library = maybe_library orelse std.debug.panic("library {s} lacks an external", .{spec.name});
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

/// Runs one library's tests for a step narrower than `test-libraries`.
///
/// ```zig
/// transport_step.dependOn(libraries.addTestRun(b, "localsocket"));
/// ```
pub fn addTestRun(self: Libraries, b: *std.Build, name: []const u8) *std.Build.Step {
    const tests = b.addTest(.{
        .name = b.fmt("lib-{s}", .{name}),
        .root_module = self.get(name),
    });
    return &b.addRunArtifact(tests).step;
}

/// Analyzes every library that supports `target`, tests included, so each
/// operating-system branch compiles somewhere. Replaced libraries are skipped.
///
/// ```zig
/// Libraries.create(b, windows, .Debug, externals, &.{}).addChecks(b, cross_step, windows);
/// ```
pub fn addChecks(self: Libraries, b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget) void {
    for (specs, self.modules) |spec, maybe_library| {
        const library = maybe_library orelse continue;
        if (spec.host_only or (spec.posix and target.result.os.tag == .windows)) {
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

    return std.mem.indexOfScalar(?*std.Build.Module, &self.modules, module) != null;
}

/// A library declared before position `limit` in `specs`, or null when it,
/// or an external it needs, is missing from this graph.
fn declared(self: Libraries, name: []const u8, limit: usize) ?*std.Build.Module {
    for (specs[0..limit], 0..) |spec, index| {
        if (std.mem.eql(u8, spec.name, name)) {
            return self.modules[index];
        }
    }

    return null;
}

fn addPrefixes(b: *std.Build, module: *std.Build.Module, spec: Spec, prefixes: []const Prefix) void {
    for (spec.system_libraries) |library| {
        for (prefixes) |prefix| {
            if (!std.mem.eql(u8, prefix.library, library)) {
                continue;
            }

            module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix.path, "include" }) });
            module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix.path, "lib" }) });
        }
    }
}

fn find(externals: []const External, name: []const u8) ?*std.Build.Module {
    for (externals) |external| {
        if (std.mem.eql(u8, external.name, name)) {
            return external.module;
        }
    }

    return null;
}
