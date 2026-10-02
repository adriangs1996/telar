//! Suggestion states inside the palette's shared search and action frame.
const data = @import("model");
const client = @import("telar-client");
const Canvas = @import("../Canvas.zig");
const FormButton = @import("../FormButton.zig");
const PaletteLayout = @import("PaletteLayout.zig");
const WrappedLines = @import("WrappedLines.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const SuggestionPanel = @This();

bounds: Rect,
footer_bounds: Rect,
projection: *const client.Projection,

/// A ready command is the only state that paints a code preview. Enter
/// generates or pastes through the existing prompt transition.
/// Example: `try panel.draw(canvas);`
pub fn draw(self: SuggestionPanel, canvas: *Canvas) !void {
    const state = self.projection.suggestion;
    const colors = canvas.theme.palette;
    const px = canvas.chrome;
    const content = PaletteLayout.inset(self.bounds, px.px(18));
    const first = canvas.quads.items().len;
    const heading_height = @min(content.height, px.rowHeight(.body) + px.px(8));
    const heading: []const u8 = switch (state.phase) {
        .idle => "Start with a task",
        .waiting => "Generating a command…",
        .ready => "Suggested command",
        .failed => "Could not generate a command",
    };
    _ = try canvas.textAt(.{ .x = content.x, .y = content.y, .width = content.width, .height = heading_height }, .{ .text = heading, .face = .sans, .size = .body, .bold = true, .color = if (state.phase == .failed) colors.red else colors.text });
    var body: Rect = .{ .x = content.x, .y = content.y + heading_height + px.px(8), .width = content.width, .height = @max(0, content.height - heading_height - px.px(8)) };
    if (state.phase == .ready) {
        try canvas.fillRoundedAt(body, .{ .color = colors.surface0, .radius = px.px(6) });
        body = PaletteLayout.inset(body, px.px(12));
        var painter = canvas.*;
        const height = @max(1, px.body);
        painter.metrics = .{ .cell_width = try canvas.atlas.cellWidth(height), .cell_height = @intCast(@min(65535, try canvas.atlas.lineHeight(height))), .baseline = @floatFromInt(try canvas.atlas.ascender(height)), .pixel_height = height };
        const line_height: f32 = @floatFromInt(painter.metrics.cell_height);
        const columns: u16 = @intFromFloat(@min(65535, @max(1, @floor(body.width / @as(f32, @floatFromInt(painter.metrics.cell_width))))));
        var lines: WrappedLines = .{ .text = state.textSlice(), .width = columns };
        var y = body.y;
        while (y + line_height <= body.y + body.height) : (y += line_height) {
            const line = lines.next() orelse break;
            if (y + line_height * 2 > body.y + body.height and lines.next() != null) {
                _ = try canvas.textAt(.{ .x = body.x, .y = y, .width = body.width, .height = line_height }, .{ .text = "Preview shortened. Review the full command after pasting.", .face = .sans, .size = .small, .color = colors.text, .alpha = 0.65 });
                break;
            }

            _ = try painter.textAt(.{ .x = body.x, .y = y, .width = body.width, .height = line_height }, .{ .text = line, .color = colors.text });
        }
    } else {
        const message: []const u8 = switch (state.phase) {
            .idle => "Describe the command you need, then press Enter.",
            .waiting => "Keep editing or press Esc to cancel.",
            .failed => switch (state.status) {
                .ready => "The engine returned no command. Try again.",
                .unavailable => "Configure runtime.engine to enable suggestions.",
                .timeout => "The engine timed out. Try again.",
                .failed => "The engine could not answer. Try again.",
            },
            .ready => unreachable,
        };
        _ = try canvas.textAt(.{ .x = body.x, .y = body.y, .width = body.width, .height = @min(body.height, px.rowHeight(.body)) }, .{ .text = message, .face = .sans, .size = .body, .color = colors.text, .alpha = 0.65 });
    }

    canvas.quads.clipFrom(first, self.bounds);
    try self.footer(canvas);
}

fn footer(self: SuggestionPanel, canvas: *Canvas) !void {
    const state = self.projection.suggestion;
    const prompt = self.projection.prompt.?;
    const bounds = self.footer_bounds;
    const px = canvas.chrome;
    try canvas.fillAt(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = @min(px.px(1), bounds.height) }, canvas.theme.palette.surface1);
    const button_width = @min(px.px(170), bounds.width / 2);
    const inset = @min(px.px(14), bounds.width / 8);
    const text = if (state.phase == .ready) "Paste first, then run in shell." else "Review before pasting.";
    _ = try canvas.textAt(.{ .x = bounds.x + inset, .y = bounds.y, .width = @max(0, bounds.width - button_width - inset * 3), .height = bounds.height }, .{ .text = text, .face = .sans, .size = .small, .color = canvas.theme.palette.text, .alpha = 0.65 });
    try (FormButton{ .bounds = .{ .x = bounds.x + bounds.width - button_width - inset, .y = bounds.y + px.px(4), .width = button_width, .height = @max(0, bounds.height - px.px(8)) }, .text = switch (state.phase) {
        .idle => "Generate  ↵",
        .waiting => "Generating…",
        .ready => "Paste command  ↵",
        .failed => "Try again  ↵",
    }, .action = .{ .prompt = .submit }, .generation = prompt.generation, .namespace = 2, .quiet = true, .enabled = state.phase != .waiting and (state.phase == .ready or prompt.paletteQuery().len != 0) }).draw(canvas);
}
