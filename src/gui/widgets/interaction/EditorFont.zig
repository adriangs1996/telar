//! Resident shaping shared by composer painting and native input.
const core = @import("telar-core");
const Font = @This();

atlas: *@import("../../text/GlyphAtlas.zig"),
pixel_height: u16,

pub const max_bytes = 8192;

/// Measures a complete shaped span without font discovery.
/// Example: `const width = font.measure(line);`
pub fn measure(font: Font, text: []const u8) u16 {
    const advance = font.atlas.measureResident(.{ .text = text, .x = 0, .y = 0, .color = .white, .face = .sans, .pixel_height = font.pixel_height }) catch return @intCast(@min(65535, core.measure(text)));
    return @intFromFloat(@max(0, @min(65535, @round(advance))));
}

/// Writes visual positions for every grapheme boundary in one bounded span.
/// Example: `font.positions(line, scratch[0 .. line.len + 1]);`
pub fn positions(font: Font, text: []const u8, output: []u32) void {
    @import("std").debug.assert(output.len == text.len + 1);
    font.atlas.caretPositions(.{ .text = text, .x = 0, .y = 0, .color = .white, .face = .sans, .pixel_height = font.pixel_height }, output) catch {
        var iterator: core.GraphemeIterator = .{ .bytes = text };
        var width: u32 = 0;
        output[0] = 0;
        while (iterator.next()) |cluster| {
            @memset(output[iterator.index - cluster.bytes.len .. iterator.index], width);
            width += cluster.width;
            output[iterator.index] = width;
        }
    };
}

/// Resolves fallback faces while preparing the frame, before native input uses
/// the resident-only measurement path. Example: `try font.prepare(text);`
pub fn prepare(font: Font, text: []const u8) !void {
    try font.atlas.prepareEditor();
    var paragraphs = @import("std").mem.tokenizeAny(u8, text, "\r\n");
    while (paragraphs.next()) |paragraph| {
        _ = try font.atlas.measure(.{ .text = paragraph, .x = 0, .y = 0, .color = .white, .face = .sans, .pixel_height = font.pixel_height });
    }
}
