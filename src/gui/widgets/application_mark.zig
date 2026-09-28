//! The mark of a foreground application in chrome: the embedded provider
//! sprite of a built-in agent, else the icon theme's glyph. Tabs and the
//! fullscreen band draw the same mark, so a pane and its tab agree.
const core = @import("telar-core");
const data = @import("model");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const Canvas = @import("Canvas.zig");

/// Sprite alpha of a mark whose pane is hidden or not selected.
pub const dimmed_alpha: f32 = 0.6;

/// Fits the mark inside `bounds`; a dimmed mark reads as an unfocused pane.
/// Example: `try application_mark.draw(canvas, icon, bounds, false);`
pub fn draw(canvas: *Canvas, icon: data.icons.Icon, bounds: Rect, dimmed: bool) !void {
    const palette = canvas.theme.palette;
    const provider: core.AgentProvider = switch (icon) {
        .provider_claude => .claude,
        .provider_codex => .codex,
        .provider_pi => .pi,
        .provider_cursor => .cursor,
        else => .unknown,
    };
    if (canvas.providerMark(provider)) |mark| {
        try canvas.spriteTintedAt(bounds, .{
            .sprite = mark,
            .color = if (data.icons.providerMarkFollowsTheme(provider)) palette.text else .default,
            .alpha = if (dimmed) dimmed_alpha else 1,
        });
        return;
    }

    try canvas.iconAt(bounds, .{
        .text = icon.nerdGlyph(),
        .color = if (dimmed) palette.overlay1 else palette.subtext0,
        .face = .sans,
        .size = .body,
    });
}
