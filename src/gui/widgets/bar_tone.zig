//! Resolves a component's tone and legacy colours against the theme, so
//! configured bars follow every theme.
const cellgrid = @import("cellgrid");
const data = @import("model");
const Canvas = @import("Canvas.zig");

/// The ink of text in this tone.
/// Example: `const color = bar_tone.ink(canvas, node.tone);`
pub fn ink(canvas: *const Canvas, tone: data.Tone) cellgrid.Color {
    return role(canvas, tone.inkRole());
}

/// The fill of a meter, a sparkline or an icon in this tone.
/// Example: `const fill = bar_tone.mark(canvas, node.tone);`
pub fn mark(canvas: *const Canvas, tone: data.Tone) cellgrid.Color {
    return role(canvas, tone.markRole());
}

/// Resolves a legacy segment colour, a palette role or a literal.
/// Example: `const color = bar_tone.color(canvas, style.foreground.?);`
pub fn color(canvas: *const Canvas, value: data.bar_values.Color) cellgrid.Color {
    return switch (value) {
        .value => |literal| literal,
        .palette => |palette_role| role(canvas, palette_role),
    };
}

fn role(canvas: *const Canvas, palette_role: data.bar_values.PaletteColor) cellgrid.Color {
    return switch (palette_role) {
        inline else => |field| @field(canvas.theme.palette, @tagName(field)),
    };
}
