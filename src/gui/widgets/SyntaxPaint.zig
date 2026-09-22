//! Tokens supply color, while the existing grapheme iterator owns cell geometry.
const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Fragment = @import("SyntaxFragment.zig");
const Self = @This();

source: []const u8 = "",
roles: ?[]const data.role.Role = null,

/// Draws a borrowed fragment from retained source, including wrapped token tails.
/// Token boundaries cannot split combining sequences or change glyph positions.
/// Example: `try syntax.draw(canvas, .{ .bounds = area, .text = fragment });`
pub fn draw(self: *Self, canvas: *Canvas, fragment: Fragment) !void {
    const start = @intFromPtr(fragment.text.ptr) - @intFromPtr(self.source.ptr);
    var graphemes: core.GraphemeIterator = .{ .bytes = fragment.text };
    var area = fragment.bounds;
    while (graphemes.index < fragment.text.len) {
        const offset = start + graphemes.index;
        const cluster = graphemes.next().?;
        const role = if (self.roles) |roles| roles[offset] else .plain;
        const style = canvas.theme.syntaxStyle(role);
        const advance = try canvas.textAt(area, .{ .text = cluster.bytes, .color = style.color, .italic = style.italic, .bold = style.bold });
        area.x += advance;
        area.width = @max(0, area.width - advance);
    }
}
