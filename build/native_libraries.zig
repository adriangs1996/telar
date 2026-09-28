const std = @import("std");
const NativeLibrary = @import("NativeLibrary.zig");

/// Resolves the C libraries the standalone libraries link. Each is compiled
/// from the sources pinned in `build.zig.zon` and linked statically, so a
/// release depends only on the operating system. `-Dbrotli=`, `-Dnghttp2=`
/// and `-Dsqlite=` name a system installation instead, for distribution
/// packages. macOS keeps its own SQLite, which every macOS ships and Apple
/// patches.
///
/// ```zig
/// const natives = native_libraries.create(b, target, .ReleaseFast);
/// ```
pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const NativeLibrary {
    const brotli_prefix = b.option([]const u8, "brotli", "Link the libbrotlidec installed under this prefix instead of building it");
    const nghttp2_prefix = b.option([]const u8, "nghttp2", "Link the libnghttp2 installed under this prefix instead of building it");
    const sqlite_prefix = b.option([]const u8, "sqlite", "Link the libsqlite3 installed under this prefix instead of building it");
    const natives = b.allocator.alloc(NativeLibrary, 3) catch @panic("OOM");
    natives[0] = .{
        .library = "brotlidec",
        .source = if (brotli_prefix) |prefix| .{ .system = prefix } else .{ .built = brotli(b, target, optimize) },
    };
    natives[1] = .{
        .library = "nghttp2",
        .source = if (nghttp2_prefix) |prefix| .{ .system = prefix } else .{ .built = nghttp2(b, target, optimize) },
    };
    natives[2] = .{
        .library = "sqlite3",
        .source = if (sqlite_prefix) |prefix|
            .{ .system = prefix }
        else if (target.result.os.tag == .macos)
            .{ .system = null }
        else
            .{ .built = sqlite(b, target, optimize) },
    };
    return natives;
}

/// Every library from its pinned sources, for the portability checks of
/// targets this machine is not, where no system copy exists.
///
/// ```zig
/// const natives = native_libraries.portable(b, windows, .Debug);
/// ```
pub fn portable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const NativeLibrary {
    const natives = b.allocator.alloc(NativeLibrary, 3) catch @panic("OOM");
    natives[0] = .{
        .library = "brotlidec",
        .source = .{ .built = brotli(b, target, optimize) },
    };
    natives[1] = .{
        .library = "nghttp2",
        .source = .{ .built = nghttp2(b, target, optimize) },
    };
    natives[2] = .{
        .library = "sqlite3",
        .source = .{ .built = sqlite(b, target, optimize) },
    };
    return natives;
}

fn brotli(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const upstream = b.dependency("brotli", .{});
    const library = staticLibrary(b, "brotlidec", target, optimize);
    library.root_module.addIncludePath(upstream.path("c/include"));
    library.root_module.addCSourceFiles(.{
        .root = upstream.path("c"),
        .files = &.{
            "common/constants.c",
            "common/context.c",
            "common/dictionary.c",
            "common/platform.c",
            "common/shared_dictionary.c",
            "common/transform.c",
            "dec/bit_reader.c",
            "dec/decode.c",
            "dec/huffman.c",
            "dec/prefix.c",
            "dec/state.c",
            "dec/static_init.c",
        },
        .flags = &.{"-fno-sanitize=undefined"},
    });
    library.installHeadersDirectory(upstream.path("c/include/brotli"), "brotli", .{});
    return library;
}

fn nghttp2(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const upstream = b.dependency("nghttp2", .{});
    const library = staticLibrary(b, "nghttp2", target, optimize);
    library.root_module.addIncludePath(upstream.path("lib/includes"));
    library.root_module.addCMacro("BUILDING_NGHTTP2", "1");
    library.root_module.addCMacro("NGHTTP2_STATICLIB", "1");
    if (target.result.os.tag == .windows) {
        library.root_module.addCMacro("HAVE_WINDOWS_H", "1");
        library.root_module.addCMacro("HAVE_GETTICKCOUNT64", "1");
    } else {
        library.root_module.addCMacro("HAVE_ARPA_INET_H", "1");
        library.root_module.addCMacro("HAVE_NETINET_IN_H", "1");
        library.root_module.addCMacro("HAVE_CLOCK_GETTIME", "1");
        library.root_module.addCMacro("HAVE_DECL_CLOCK_MONOTONIC", "1");
    }

    library.root_module.addCSourceFiles(.{
        .root = upstream.path("lib"),
        .files = &.{
            "nghttp2_alpn.c",
            "nghttp2_buf.c",
            "nghttp2_callbacks.c",
            "nghttp2_debug.c",
            "nghttp2_extpri.c",
            "nghttp2_frame.c",
            "nghttp2_hd.c",
            "nghttp2_hd_huffman.c",
            "nghttp2_hd_huffman_data.c",
            "nghttp2_helper.c",
            "nghttp2_http.c",
            "nghttp2_map.c",
            "nghttp2_mem.c",
            "nghttp2_option.c",
            "nghttp2_outbound_item.c",
            "nghttp2_pq.c",
            "nghttp2_priority_spec.c",
            "nghttp2_queue.c",
            "nghttp2_ratelim.c",
            "nghttp2_rcbuf.c",
            "nghttp2_session.c",
            "nghttp2_stream.c",
            "nghttp2_submit.c",
            "nghttp2_time.c",
            "nghttp2_version.c",
            "sfparse.c",
        },
        .flags = &.{"-fno-sanitize=undefined"},
    });
    library.installHeader(upstream.path("lib/includes/nghttp2/nghttp2.h"), "nghttp2/nghttp2.h");
    library.installHeader(upstream.path("lib/includes/nghttp2/nghttp2ver.h"), "nghttp2/nghttp2ver.h");
    return library;
}

/// The amalgamation with FTS5 for history search. Nothing loads SQLite
/// extensions, so the build leaves that code out.
fn sqlite(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const upstream = b.dependency("sqlite", .{});
    const library = staticLibrary(b, "sqlite3", target, optimize);
    library.root_module.addCSourceFile(.{
        .file = upstream.path("sqlite3.c"),
        .flags = &.{
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-fno-sanitize=undefined",
        },
    });
    library.installHeader(upstream.path("sqlite3.h"), "sqlite3.h");
    return library;
}

fn staticLibrary(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    return b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
}
