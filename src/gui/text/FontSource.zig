const assets = @import("assets");
const std = @import("std");
const client = @import("telar-client");
const FontMatch = @import("../native/FontMatch.zig").FontMatch;
const FontSource = @This();

extern fn telar_gui_find_font(family: [*:0]const u8, style: [*:0]const u8, match: *FontMatch) c_int;

/// Mirrors the native lookup's status codes.
const Lookup = enum(c_int) {
    found = 0,
    family_not_found = -1,
    style_not_found = -2,
    _,
};

/// The family and only style the embedded face provides.
const bundled_family = "JetBrains Mono";
const bundled_style = "Regular";

/// The largest font file the GUI reads, matching `TELAR_FONT_MAX_BYTES` in
/// the native port so a file the port reports is never refused here.
pub const max_bytes = 64 * 1024 * 1024;

bytes: []const u8 = assets.jetbrains_mono,
owned: bool = false,
match: FontMatch = .{},

/// Resolves and owns font bytes once, outside cell rendering. The bundled
/// family with another style resolves to the installed family instead.
/// Example: `var source = try FontSource.load(gpa, io, &config.font);`
pub fn load(allocator: std.mem.Allocator, io: std.Io, font: *const client.GuiFont) !FontSource {
    const family = if (font.family.len == 0) bundled_family else font.family.name();
    const style = font.style.name();
    if (std.ascii.eqlIgnoreCase(family, bundled_family) and (style.len == 0 or std.ascii.eqlIgnoreCase(style, bundled_style))) {
        return .{};
    }

    var match: FontMatch = .{};
    switch (@as(Lookup, @enumFromInt(telar_gui_find_font(family.ptr, style.ptr, &match)))) {
        .found => {},
        .style_not_found => return error.FontStyleNotFound,
        else => return error.FontFamilyNotFound,
    }

    const path = std.mem.sliceTo(&match.path, 0);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
    return .{ .bytes = bytes, .owned = true, .match = match };
}

pub fn deinit(self: *FontSource, allocator: std.mem.Allocator) void {
    if (self.owned) {
        allocator.free(self.bytes);
    }

    self.* = .{};
}
