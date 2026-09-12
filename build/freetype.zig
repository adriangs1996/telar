const std = @import("std");
const FreeTypeConfig = @import("FreeTypeConfig.zig");
const c_flags = @import("c_flags.zig");

/// Builds the same static FreeType and HarfBuzz sources Ghostty uses for font
/// faces and shaping. Telar leaves system zlib disabled, so FreeType's bundled
/// gzip decoder remains self-contained and the frontend gains no runtime
/// library dependency.
pub fn add(b: *std.Build, config: FreeTypeConfig) *std.Build.Module {
    const target = config.target;
    const disable_coverage = config.disable_coverage;
    const upstream = b.dependency("freetype", .{});
    const harfbuzz = b.dependency("harfbuzz", .{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/frontend/graphics/freetype.zig"),
        .target = target,
        .optimize = config.optimize,
        .link_libc = true,
        .link_libcpp = target.result.abi != .msvc,
    });
    module.addIncludePath(upstream.path("include"));
    module.addIncludePath(harfbuzz.path("src"));
    const base_flags: []const []const u8 = if (target.result.os.tag == .windows)
        &.{
            "-DFT2_BUILD_LIBRARY",
            "-fno-sanitize=undefined",
        }
    else
        &.{
            "-DFT2_BUILD_LIBRARY",
            "-DHAVE_UNISTD_H",
            "-DHAVE_FCNTL_H",
            "-fno-sanitize=undefined",
        };
    const flags = c_flags.forCoverage(b, base_flags, disable_coverage);
    module.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = freetype_sources,
        .flags = flags,
    });
    module.addCSourceFile(.{
        .file = if (target.result.os.tag == .linux)
            upstream.path("builds/unix/ftsystem.c")
        else if (target.result.os.tag == .windows)
            upstream.path("builds/windows/ftsystem.c")
        else
            upstream.path("src/base/ftsystem.c"),
        .flags = flags,
    });
    module.addCSourceFile(.{
        .file = if (target.result.os.tag == .windows)
            upstream.path("builds/windows/ftdebug.c")
        else
            upstream.path("src/base/ftdebug.c"),
        .flags = flags,
    });
    const harfbuzz_base_flags: []const []const u8 = if (target.result.os.tag == .windows)
        &.{
            "-DHAVE_STDBOOL_H",
            "-DHAVE_FREETYPE=1",
            "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_DONE_MM_VAR=1",
            "-DHAVE_FT_GET_TRANSFORM=1",
            "-fno-sanitize=undefined",
        }
    else
        &.{
            "-DHAVE_STDBOOL_H",
            "-DHAVE_UNISTD_H",
            "-DHAVE_SYS_MMAN_H",
            "-DHAVE_PTHREAD=1",
            "-DHAVE_FREETYPE=1",
            "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_DONE_MM_VAR=1",
            "-DHAVE_FT_GET_TRANSFORM=1",
        };
    const harfbuzz_flags = c_flags.forCoverage(b, harfbuzz_base_flags, disable_coverage);
    module.addCSourceFile(.{
        .file = harfbuzz.path("src/harfbuzz.cc"),
        .flags = harfbuzz_flags,
    });
    return module;
}

const freetype_sources: []const []const u8 = &.{
    "src/autofit/autofit.c",
    "src/base/ftbase.c",
    "src/base/ftbbox.c",
    "src/base/ftbdf.c",
    "src/base/ftbitmap.c",
    "src/base/ftcid.c",
    "src/base/ftfstype.c",
    "src/base/ftgasp.c",
    "src/base/ftglyph.c",
    "src/base/ftgxval.c",
    "src/base/ftinit.c",
    "src/base/ftmm.c",
    "src/base/ftotval.c",
    "src/base/ftpatent.c",
    "src/base/ftpfr.c",
    "src/base/ftstroke.c",
    "src/base/ftsynth.c",
    "src/base/fttype1.c",
    "src/base/ftwinfnt.c",
    "src/bdf/bdf.c",
    "src/bzip2/ftbzip2.c",
    "src/cache/ftcache.c",
    "src/cff/cff.c",
    "src/cid/type1cid.c",
    "src/gzip/ftgzip.c",
    "src/lzw/ftlzw.c",
    "src/pcf/pcf.c",
    "src/pfr/pfr.c",
    "src/psaux/psaux.c",
    "src/pshinter/pshinter.c",
    "src/psnames/psnames.c",
    "src/raster/raster.c",
    "src/sdf/sdf.c",
    "src/sfnt/sfnt.c",
    "src/smooth/smooth.c",
    "src/svg/svg.c",
    "src/truetype/truetype.c",
    "src/type1/type1.c",
    "src/type42/type42.c",
    "src/winfonts/winfnt.c",
};
