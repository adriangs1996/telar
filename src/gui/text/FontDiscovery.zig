//! Answers the font set's queued graphemes off the render thread, one at a
//! time: the native lookup (CoreText or Fontconfig, tens of milliseconds
//! for a grapheme no installed face covers) and the read of the matched
//! file run on an inbox worker; the set adopts the answer between frames.
//! The GUI owns the worker's output even if shutdown drops its notification.
const gui_event = @import("../gui_event.zig");
const std = @import("std");
const FontSet = @import("FontSet.zig");
const FontQuery = @import("FontQuery.zig");
const FontSource = @import("FontSource.zig");
const FontCandidate = @import("FontCandidate.zig");
const FontMatch = @import("../native/FontMatch.zig").FontMatch;
const FontDiscovery = @This();

extern fn telar_gui_find_fallback_font(text: [*:0]const u8, match: *FontMatch) callconv(.c) c_int;

/// Frees the file bytes a found face carries; the renderer's allocator,
/// which is the one the font set frees adopted faces with.
allocator: std.mem.Allocator,
query: ?FontQuery = null,
/// Written by the worker before it publishes, read after the inbox delivers.
candidate: ?FontCandidate = null,

/// Example: `var discovery = FontDiscovery.init(gpa);`
pub fn init(allocator: std.mem.Allocator) FontDiscovery {
    return .{ .allocator = allocator };
}

/// Call only after the inbox has cancelled and joined its producers.
/// Example: `discovery.deinit();`
pub fn deinit(self: *FontDiscovery) void {
    if (self.candidate) |found| {
        self.allocator.free(found.bytes);
    }

    self.* = undefined;
}

/// Starts a lookup for the set's oldest queued grapheme unless one is in
/// flight. A worker that cannot start leaves the grapheme a miss, so a
/// full inbox never makes the set ask again every frame.
/// Example: `discovery.start(&inbox, &atlas.fonts, io);`
pub fn start(self: *FontDiscovery, inbox: *gui_event.Inbox, fonts: *FontSet, io: std.Io) void {
    if (self.query != null) {
        return;
    }

    const query = fonts.takeQuery() orelse return;
    self.query = query;
    inbox.start(.font_discovered, .{ execute, .{ self, io } }) catch {
        _ = fonts.adopt(self.allocator, &query, null);
        self.query = null;
    };
}

/// Runs on the inbox worker and publishes only a void notification.
/// Example: `try inbox.start(.font_discovered, .{ FontDiscovery.execute, .{ discovery, io } });`
pub fn execute(self: *FontDiscovery, io: std.Io) void {
    const query = &self.query.?;
    var match: FontMatch = .{};
    if (telar_gui_find_fallback_font(query.codepoints().ptr, &match) != 0) {
        return;
    }

    const path = std.mem.sliceTo(&match.path, 0);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(FontSource.max_bytes)) catch return;
    self.candidate = .{ .match = match, .bytes = bytes };
}

/// Hands the finished lookup to `fonts` when it is still the set that
/// asked, and frees it otherwise. Returns whether the set's resident
/// order changed, so cells drawn with the replacement glyph repaint.
/// Example: `if (discovery.finish(&atlas.fonts)) renderer.retained.invalidate();`
pub fn finish(self: *FontDiscovery, fonts: ?*FontSet) bool {
    const query = self.query orelse return false;
    const candidate = self.candidate;
    self.query = null;
    self.candidate = null;
    const set = fonts orelse return self.discard(candidate);
    if (set.identity != query.set_identity) {
        return self.discard(candidate);
    }

    return set.adopt(self.allocator, &query, candidate);
}

fn discard(self: *FontDiscovery, candidate: ?FontCandidate) bool {
    if (candidate) |found| {
        self.allocator.free(found.bytes);
    }

    return false;
}
