//! The standalone libraries under `lib/`. A library imports only `std`,
//! external dependencies and other libraries, never a telar module, so the
//! compiler keeps telar state and policy out of it.
const std = @import("std");
const External = @import("LibraryExternal.zig");
const NativeLibrary = @import("NativeLibrary.zig");
const macos_sdk = @import("macos_sdk.zig");
const window_build = @import("window.zig");
const Libraries = @This();

/// Imports a spec may declare.
const max_imports = 4;

const Spec = struct {
    /// Module name and the alias consumers import it as.
    name: []const u8,
    /// Defaults to the module name when its directory under `lib/` matches.
    directory: ?[]const u8 = null,
    /// Root for libraries whose public struct is the module itself.
    root: []const u8 = "root.zig",
    /// Selects a platform implementation as the module root; other targets omit it.
    platform_roots: ?struct { macos: []const u8, linux: []const u8 } = null,
    /// Libraries listed earlier in `specs`, or externals the caller provides.
    /// A library whose external is not provided is left out of that graph.
    imports: []const []const u8 = &.{},
    libc: bool = false,
    /// Built only for POSIX targets.
    posix: bool = false,
    /// C libraries it links: the caller's `NativeLibrary` of that name, or
    /// else the system's. A system copy links only for a target that runs on
    /// the host; other targets still analyze packages that import it.
    system_libraries: []const []const u8 = &.{},
    /// Frameworks linked when the target is macOS.
    macos_frameworks: []const []const u8 = &.{},
    /// Portability checks skip it.
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
    // Before its importers: a library imports only those declared above it.
    .{
        .name = "privatefile",
        .libc = true,
        .posix = true,
    },
    .{
        .name = "localsocket",
        .imports = &.{"privatefile"},
        .libc = true,
        .posix = true,
    },
    .{
        .name = "mailbox",
    },
    .{
        .name = "slabheap",
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
        .name = "cblocks",
    },
    .{
        .name = "sqlite",
        .imports = &.{"cblocks"},
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
        .imports = &.{"privatefile"},
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
        .name = "telar-window",
        .directory = "window",
        .imports = &.{ "keyinput", "gfx" },
        .libc = true,
        .host_only = true,
        .macos_frameworks = &.{ "AppKit", "CoreFoundation", "CoreGraphics", "QuartzCore", "ImageIO" },
        .platform_roots = .{
            .macos = "MacosWindow.zig",
            .linux = "LinuxWindow.zig",
        },
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
        .imports = &.{"cblocks"},
        .libc = true,
        .system_libraries = &.{"brotlidec"},
    },
    .{
        .name = "httprelay",
        .imports = &.{ "localca", "h2frames", "cblocks" },
        .libc = true,
        .system_libraries = &.{"nghttp2"},
    },
    .{
        .name = "childoutput",
    },
    .{
        .name = "gitstatus",
        .imports = &.{"childoutput"},
    },
    .{
        .name = "proclineage",
        .libc = true,
        .posix = true,
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
};

/// Null on unsupported platforms or when this graph lacks an external dependency.
modules: [specs.len]?*std.Build.Module,
externals: []const External,
/// Internal platform bindings; never added to application package imports.
metal: ?*std.Build.Module = null,

/// Builds every library for one target, the way `Application` and the
/// benchmark graph each need their own copy. An external named like a
/// library replaces it, as the portability checks do with the width table.
///
/// ```zig
/// const libraries = Libraries.create(b, target, optimize, &.{.{ .name = "ghostty-vt", .module = ghostty_vt }}, natives);
/// ```
pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, externals: []const External, natives: []const NativeLibrary) Libraries {
    var self: Libraries = .{
        // SAFETY: The specs loop assigns each slot before dependency lookup can see it; declared limits lookup to earlier indices.
        .modules = undefined,
        .externals = b.allocator.dupe(External, externals) catch @panic("OOM"),
    };

    if (target.result.os.tag == .macos) {
        const objc = b.dependency("zig_objc", .{
            .target = target,
            .optimize = optimize,
            .@"add-paths" = false,
        }).module("objc");
        macos_sdk.addPaths(b, objc);
        self.externals = std.mem.concat(b.allocator, External, &.{ self.externals, &.{.{ .name = "objc", .module = objc }} }) catch @panic("OOM");
        const metal = b.createModule(.{
            .root_source_file = b.path("lib/window/metal/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        metal.addImport("objc", objc);
        macos_sdk.addPaths(b, metal);
        for ([_][]const u8{ "Metal", "QuartzCore", "Foundation" }) |framework| {
            metal.linkFramework(framework, .{});
        }

        self.metal = metal;
    }

    for (specs, 0..) |spec, index| {
        if (spec.platform_roots != null and target.result.os.tag != .macos and target.result.os.tag != .linux) {
            self.modules[index] = null;
            continue;
        }

        if (find(externals, spec.name)) |replacement| {
            self.modules[index] = replacement;
            continue;
        }

        self.modules[index] = null;
        var dependencies: [max_imports]*std.Build.Module = undefined;
        for (spec.imports, 0..) |name, position| {
            dependencies[position] = find(self.externals, name) orelse self.declared(name, index) orelse break;
        } else {
            self.modules[index] = build(b, spec, target, optimize, dependencies[0..spec.imports.len]);
            if (std.mem.eql(u8, spec.name, "telar-window")) {
                const module = self.modules[index].?;
                if (target.result.os.tag == .macos) {
                    module.addImport("objc", find(self.externals, "objc").?);
                    module.addImport("metal", self.metal.?);
                    window_build.addMacos(b, module);
                } else if (target.query.cpu_arch == null and target.query.isNativeOs() and target.query.isNativeAbi()) {
                    // Wayland's generated and system headers resolve only for
                    // the native architecture, OS and ABI; an explicit target
                    // never sees them. A baseline CPU model still does.
                    window_build.addWayland(b, module);
                }
            }

            linkNatives(b, self.modules[index].?, spec, natives);
        }
    }

    return self;
}

fn build(b: *std.Build, spec: Spec, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, dependencies: []const *std.Build.Module) *std.Build.Module {
    const root = if (spec.platform_roots) |roots| switch (target.result.os.tag) {
        .macos => roots.macos,
        .linux => roots.linux,
        else => unreachable,
    } else spec.root;

    const module = b.createModule(.{
        .root_source_file = b.path(b.pathJoin(&.{ "lib", spec.directory orelse spec.name, root })),
        .target = target,
        .optimize = optimize,
        .link_libc = spec.libc,
    });
    for (spec.imports, dependencies) |name, dependency| {
        module.addImport(name, dependency);
    }

    if (target.result.os.tag == .macos and spec.macos_frameworks.len > 0) {
        macos_sdk.addPaths(b, module);
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

/// Fails the build graph if a library imports anything that is not another
/// library or a declared external.
///
/// ```zig
/// libraries.checkImports();
/// ```
pub fn checkImports(self: Libraries) void {
    for (specs, self.modules) |spec, maybe_library| {
        if ((spec.platform_roots != null or spec.host_only) and maybe_library == null) {
            continue;
        }

        const library = maybe_library orelse std.debug.panic("library {s} lacks an external", .{spec.name});
        for (library.import_table.values()) |dependency| {
            if (!self.contains(dependency)) {
                std.debug.panic("library {s} imports a module outside lib/", .{spec.name});
            }
        }
    }
}

fn contains(self: Libraries, module: *std.Build.Module) bool {
    if (self.metal == module) {
        return true;
    }

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

fn linkNatives(b: *std.Build, module: *std.Build.Module, spec: Spec, natives: []const NativeLibrary) void {
    for (spec.system_libraries) |library| {
        const native = findNative(natives, library);
        switch (native.source) {
            .built => |static| module.linkLibrary(static),
            .system => |maybe_prefix| {
                if (!onHost(b, module.resolved_target.?)) {
                    continue;
                }

                module.linkSystemLibrary(library, .{});
                macos_sdk.addPaths(b, module);
                if (maybe_prefix) |prefix| {
                    module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
                    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
                }
            },
        }
    }
}

/// Whether `target` runs on this machine's system, where its libraries are
/// found. A pinned CPU or OS version still counts, as release builds use them.
fn onHost(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = b.graph.host.result;
    return target.result.os.tag == host.os.tag and target.result.cpu.arch == host.cpu.arch and target.result.abi == host.abi;
}

/// The caller's provider for `library`, or the system's default search paths.
fn findNative(natives: []const NativeLibrary, library: []const u8) NativeLibrary {
    for (natives) |native| {
        if (std.mem.eql(u8, native.library, library)) {
            return native;
        }
    }

    return .{
        .library = library,
        .source = .{ .system = null },
    };
}

fn find(externals: []const External, name: []const u8) ?*std.Build.Module {
    for (externals) |external| {
        if (std.mem.eql(u8, external.name, name)) {
            return external.module;
        }
    }

    return null;
}
