const client = @import("telar-client");
const Modal = @import("Modal.zig");

const Canvas = @import("../chrome/Canvas.zig");
const SuggestionModal = @This();

area: @import("telar-core").Rect,
projection: *const client.Projection,

/// Paints the engine's owned response without running engine work in the GUI.
/// Example: `try widget.draw(canvas);`
pub fn draw(widget: SuggestionModal, canvas: *Canvas) !void {
    const modal: Modal = .{ .canvas = canvas, .area = widget.area };
    const projection = widget.projection.*;
    const state = projection.suggestion;
    const palette = modal.canvas.theme.palette;
    const text: []const u8 = switch (state.phase) {
        .idle => "Describe the command you need",
        .waiting => "Asking the engine...",
        .ready => state.textSlice(),
        .failed => switch (state.status) {
            .ready => "The engine returned no command",
            .unavailable => "No engine configured (runtime.engine)",
            .timeout => "The engine timed out",
            .failed => "The engine could not answer",
        },
    };
    const hint: []const u8 = switch (state.phase) {
        .idle => "Enter ask  Esc cancel",
        .waiting => "Esc cancel",
        .ready => "Enter paste  Esc cancel",
        .failed => "Enter retry  Esc cancel",
    };
    try modal.frame("Suggest a command");

    const content = modal.content();
    try modal.field(content.row(0), projection.prompt.?);

    if (content.h > 2) {
        try modal.line(2, .{ .text = text, .color = if (state.phase == .failed) palette.red else palette.text });
        try modal.line(content.h - 1, .{ .text = hint, .color = palette.subtext0 });
    }
}
