//! Native chrome adapter: paints the client's semantic projection on a GPU.
//! Shared client controllers own the session; native backends deliver input
//! and consume sealed cell frames without knowing the terminal protocol.

pub const Application = @import("Application.zig");
pub const Color = @import("render/Color.zig");
pub const GlyphAtlas = @import("text/GlyphAtlas.zig");
pub const QuadList = @import("render/QuadList.zig");
pub const Rect = @import("render/Rect.zig");
pub const TextRun = @import("text/TextRun.zig");
pub const cell_colors = @import("render/cell_colors.zig");
pub const run = @import("run.zig").run;
pub const quad = @import("render/Quad.zig");
pub const Canvas = @import("chrome/Canvas.zig");
pub const Layout = @import("layout/Layout.zig");
pub const LayoutItem = @import("layout/Item.zig");
pub const GenericWidgetList = @import("widgets/GenericWidgetList.zig").Type;
pub const InputEvent = @import("input/event.zig").Event;
pub const PointerEvent = @import("input/PointerEvent.zig");
pub const TextInput = @import("input/TextInput.zig");

test {
    _ = @import("tests/top_navigation.zig");
    _ = @import("tests/status_bar.zig");
    _ = @import("tests/widget_interaction.zig");
    _ = Layout;
    _ = @import("input/GenericEventPool.zig");
    _ = @import("host/Services.zig");
    _ = @import("tests/widgets.zig");
    _ = @import("tests/widget_animation.zig");
    _ = @import("tests/widget_composition.zig");
    _ = @import("tests/host_input.zig");
    _ = @import("animation/FrameClock.zig");
    _ = @import("animation/Transition.zig");
    _ = @import("native/decode_input.zig");
    _ = @import("tests/links.zig");
    _ = @import("tests/link_metadata.zig");
    _ = @import("tests/link_regressions.zig");
    _ = Application;
    _ = @import("WindowIdentity.zig");
    _ = @import("tests/terminal.zig");
    _ = @import("tests/configuration.zig");
    _ = @import("tests/font_thicken.zig");
    _ = @import("tests/font_fallback.zig");
    _ = @import("text/font_id.zig");
    _ = @import("text/GraphemeMisses.zig");
    _ = @import("tests/braille.zig");
    _ = @import("tests/box_drawing.zig");
    _ = @import("tests/italic.zig");
    _ = @import("tests/navigation.zig");
    _ = @import("tests/chrome.zig");
    _ = @import("tests/composition_budget.zig");
    _ = @import("tests/overlays.zig");
    _ = @import("tests/notifications.zig");
    _ = @import("tests/scene.zig");
    _ = @import("tests/visual_language.zig");
    _ = @import("tests/sidebar_cards.zig");
    _ = @import("tests/sprites.zig");
    _ = @import("tests/palette.zig");
    _ = @import("tests/visual_chrome.zig");
    _ = @import("tests/sidebar_band.zig");
    _ = @import("tests/chrome_sizes.zig");
    _ = @import("TerminalMetrics.zig");
    _ = @import("NativeInput.zig");
    _ = @import("CursorClock.zig");
    _ = GlyphAtlas;
    _ = QuadList;
    _ = cell_colors;
}
