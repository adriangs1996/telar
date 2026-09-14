const std = @import("std");
const client = @import("telar-client");
const FontMatch = @import("../native/FontMatch.zig").FontMatch;
const FontSource = @This();

extern fn telar_gui_find_font(family: [*:0]const u8, match: *FontMatch) c_int;

/// The largest font file the GUI reads, matching `TELAR_FONT_MAX_BYTES` in
/// the native port so a file the port reports is never refused here.
pub const max_bytes = 64 * 1024 * 1024;

bytes: []const u8 = @import("assets").jetbrains_mono,
owned: bool = false,
match: FontMatch = .{},

/// Resolves and owns font bytes once, outside cell rendering.
/// Example: `var source = try FontSource.load(gpa, io, &config.font.family);`
pub fn load(allocator: std.mem.Allocator, io: std.Io, family: *const client.FontFamily) !FontSource {
    if (family.len == 0 or std.ascii.eqlIgnoreCase(family.name(), "JetBrains Mono")) {
        return .{};
    }

    var match: FontMatch = .{};
    if (telar_gui_find_font(family.name().ptr, &match) != 0) {
        return error.FontFamilyNotFound;
    }

    const path = std.mem.sliceTo(&match.path, 0);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
    return .{ .bytes = bytes, .owned = true, .match = match };
}

pub fn deinit(source: *FontSource, allocator: std.mem.Allocator) void {
    if (source.owned) {
        allocator.free(source.bytes);
    }

    source.* = .{};
}
