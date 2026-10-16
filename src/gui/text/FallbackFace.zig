//! One installed face discovered for a grapheme no resident face covers:
//! the file bytes it owns, the FreeType face borrowing them and the native
//! match that identifies the file so one face is never loaded twice.
const std = @import("std");
const FontFace = @import("FontFace.zig");
const FaceContext = @import("FaceContext.zig");
const FontMatch = @import("../native/FontMatch.zig").FontMatch;
const FallbackFace = @This();

bytes: []const u8,
face: FontFace,
match: FontMatch,

/// Opens the matched face from file bytes a background lookup read, with the
/// atlas's own options, refusing color and bitmap-only faces. Owns `bytes`
/// on success; on failure the caller still does.
/// Example: `var face = try FallbackFace.init(context, match, bytes);`
pub fn init(context: FaceContext, match: FontMatch, bytes: []const u8) !FallbackFace {
    var options = context.options;
    options.font = bytes;
    options.face_index = match.face_index;
    options.postscript = std.mem.sliceTo(&match.postscript, 0);
    options.variation = match.variation;
    var face = try FontFace.init(context.library, options, context.pixels);
    errdefer face.deinit();
    if (!face.monochrome()) {
        return error.FontFaceNotMonochrome;
    }

    return .{ .bytes = bytes, .face = face, .match = match };
}

pub fn deinit(self: *FallbackFace, allocator: std.mem.Allocator) void {
    self.face.deinit();
    allocator.free(self.bytes);
    self.* = undefined;
}

/// Whether `match` names the same file, face and instance already loaded here.
/// Example: `if (fallback.matches(match)) { ... }`
pub fn matches(self: *const FallbackFace, match: FontMatch) bool {
    return self.match.face_index == match.face_index and
        std.mem.eql(u8, std.mem.sliceTo(&self.match.path, 0), std.mem.sliceTo(&match.path, 0)) and
        std.mem.eql(u8, std.mem.sliceTo(&self.match.postscript, 0), std.mem.sliceTo(&match.postscript, 0)) and
        std.meta.eql(self.match.variation, match.variation);
}
