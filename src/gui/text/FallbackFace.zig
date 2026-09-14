//! One installed face discovered for a grapheme no resident face covers:
//! the file bytes it owns, the FreeType face borrowing them and the native
//! match that identifies the file so one face is never loaded twice.
const std = @import("std");
const FontFace = @import("FontFace.zig");
const FontSource = @import("FontSource.zig");
const FaceContext = @import("FaceContext.zig");
const FontMatch = @import("../native/FontMatch.zig").FontMatch;
const FallbackFace = @This();

bytes: []const u8,
face: FontFace,
match: FontMatch,

/// Reads the matched file within the shared bound and opens its face with
/// the atlas's own options, refusing color and bitmap-only faces.
/// Example: `var face = try FallbackFace.init(allocator, context, match);`
pub fn init(allocator: std.mem.Allocator, context: FaceContext, match: FontMatch) !FallbackFace {
    const io = context.options.io orelse return error.FontDiscoveryUnavailable;
    const path = std.mem.sliceTo(&match.path, 0);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(FontSource.max_bytes));
    errdefer allocator.free(bytes);
    var options = context.options;
    options.font = bytes;
    options.face_index = match.face_index;
    options.postscript = std.mem.sliceTo(&match.postscript, 0);
    var face = try FontFace.init(context.library, options, context.pixels);
    errdefer face.deinit();
    if (!face.monochrome()) {
        return error.FontFaceNotMonochrome;
    }

    return .{ .bytes = bytes, .face = face, .match = match };
}

pub fn deinit(fallback: *FallbackFace, allocator: std.mem.Allocator) void {
    fallback.face.deinit();
    allocator.free(fallback.bytes);
    fallback.* = undefined;
}

/// Whether `match` names the same file and face already loaded here.
/// Example: `if (fallback.matches(match)) { ... }`
pub fn matches(fallback: *const FallbackFace, match: FontMatch) bool {
    return fallback.match.face_index == match.face_index and
        std.mem.eql(u8, std.mem.sliceTo(&fallback.match.path, 0), std.mem.sliceTo(&match.path, 0)) and
        std.mem.eql(u8, std.mem.sliceTo(&fallback.match.postscript, 0), std.mem.sliceTo(&match.postscript, 0));
}
