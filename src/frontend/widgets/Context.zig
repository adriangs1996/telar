const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const context_support = @import("context_support.zig");
const Plan = @import("../ui/Plan.zig");
const std = @import("std");
const IconDraw = @import("IconDraw.zig");
/// Widgets receive no client state and cannot mutate navigation, layout,
/// transport, or runtime models.
const Context = @This();

buffer: *core.Buffer,
hits: *context_support.Hits,
palette: *const data.Palette,
hovered: ?context_support.Action,
icon_theme: data.icons.Theme = .unicode,
icon_plan: ?*Plan = null,

pub fn isHovered(self: *const Context, action: context_support.Action) bool {
    const hovered = self.hovered orelse return false;
    return std.meta.eql(hovered, action);
}

/// Draws the one-cell fallback and, when possible, records an opaque KGP
/// replacement. Indexed and terminal-default colors stay cell-rendered
/// because the client cannot reproduce colors it does not know.
/// For example: `_ = context.drawIcon(.{ .area = area, .point = point, .icon = .cpu, .style = style });`.
pub fn drawIcon(self: *Context, draw: IconDraw) u16 {
    // The telar mark is artwork with its own alpha: it takes the graphical
    // plan under every icon theme and needs no reproducible colors. Glyph
    // icons need the theme and an RGB pair for their opaque slot.
    const artwork = draw.icon == .telar_mark;
    const requested = if (self.icon_theme == .nerd_font or artwork) self.icon_plan else null;
    const foreground = draw.style.fg.rgbChannels();
    const background = draw.style.bg.rgbChannels();
    const graphical = requested != null and (artwork or (foreground != null and background != null));
    const fallback = if (graphical) draw.icon.cellFallbackGlyph() else draw.icon.unicodeGlyph();
    const written = self.buffer.writeText(draw.area, .{ .point = draw.point, .text = fallback, .style = draw.style });
    if (written != 1 or !graphical) {
        return written;
    }
    const last_x = draw.point.x + @max(draw.columns, 1) - 1;
    if (!draw.area.contains(draw.point.x, draw.point.y) or !draw.area.contains(last_x, draw.point.y) or
        !self.buffer.clip.contains(draw.point.x, draw.point.y) or !self.buffer.clip.contains(last_x, draw.point.y))
    {
        return written;
    }
    requested.?.add(.{
        .area = .{ .x = draw.point.x, .y = draw.point.y, .w = @max(draw.columns, 1), .h = 1 },
        .icon = draw.icon,
        .foreground = foreground orelse @splat(0),
        .background = background orelse @splat(0),
    });
    return written;
}
