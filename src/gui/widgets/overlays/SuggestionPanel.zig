//! Request, command preview and submission controls for the native palette.
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("../Canvas.zig");
const TextField = @import("../TextField.zig");
const FormButton = @import("../FormButton.zig");
const WrappedLines = @import("WrappedLines.zig");
const PaletteHits = @import("PaletteHits.zig");
const SuggestionPanel = @This();

area: core.Rect,
projection: *const client.Projection,
hits: *PaletteHits,

/// Fits the bounded command, reserving separate request and action rows.
/// Example: `const rows = SuggestionPanel.height(projection.suggestion, width);`
pub fn height(state: *const client.SuggestionState, width: u16) u16 {
    const lines: WrappedLines = .{ .text = state.textSlice(), .width = width -| 8 };
    return @intCast(@max(15, @min(lines.count(), 32) + 13));
}

/// Uses existing prompt controls so Enter and pointer submission share semantics.
/// Example: `try panel.draw(canvas);`
pub fn draw(panel: SuggestionPanel, target: *Canvas) !void {
    var painter = target.*;
    painter.chrome.body = @max(painter.chrome.body, @as(u16, @intFromFloat(painter.chrome.px(16))));
    painter.chrome.small = @max(painter.chrome.small, @as(u16, @intFromFloat(painter.chrome.px(14))));
    painter.chrome.title = @max(painter.chrome.title, @as(u16, @intFromFloat(painter.chrome.px(20))));
    const canvas = &painter;
    const prompt = panel.projection.prompt.?;
    const colors = canvas.theme.palette;
    var remaining = panel.area;
    if (remaining.h >= 10) {
        const header = remaining.splitTop(2);
        _ = try canvas.textAt(canvas.rect(header[0]), .{ .text = "Suggest a command", .face = .sans, .size = .title, .bold = true, .color = colors.text });
        remaining = header[1];
    }

    const field_rows: u16 = if (remaining.h >= 8) 2 else 1;
    const field_area = remaining.splitTop(field_rows);
    var field = TextField.fromPrompt(&prompt, canvas.rect(field_area[0]), .name);
    field.form_control = true;
    field.label = "Describe the command you need";
    try field.draw(canvas);
    remaining = field_area[1];

    if (remaining.h >= 7) {
        remaining = remaining.splitTop(1)[1];
        try canvas.text(remaining.row(0), .{ .text = "Suggested command", .face = .sans, .size = .small, .color = colors.accent, .bold = true });
        remaining = remaining.splitTop(1)[1];
    }

    const footer_rows: u16 = if (remaining.h >= 5) 3 else 1;
    const parts = remaining.splitBottom(footer_rows);
    const clipped = try panel.preview(canvas, parts[0]);
    var controls = parts[1];
    if (controls.h >= 3) {
        const state = panel.projection.suggestion;
        try canvas.text(controls.row(0), .{ .text = if (clipped) "Preview shortened to fit." else if (state.phase == .ready) "Paste first, then run in shell." else "Review before pasting.", .face = .sans, .size = .small, .color = colors.subtext0 });
        controls = controls.splitTop(1)[1];
    }

    try panel.footer(canvas, controls);
}

fn preview(panel: SuggestionPanel, canvas: *Canvas, area: core.Rect) !bool {
    if (area.isEmpty()) {
        return true;
    }

    const state = panel.projection.suggestion;
    const colors = canvas.theme.palette;
    try canvas.fillRounded(area, .{ .color = colors.surface0, .radius = canvas.chrome.px(8) });
    try canvas.ring(area, .{ .color = if (state.phase == .failed) colors.red else colors.accent, .width = canvas.chrome.px(1), .radius = canvas.chrome.px(8), .alpha = 0.5 });
    panel.hits.add(area);
    const content = if (area.h > 2 and area.w > 2) area.inner(1) else area;
    const text = switch (state.phase) {
        .idle => "Describe what you want to do, then press Enter.",
        .waiting => "Generating a command…",
        .ready => state.textSlice(),
        .failed => switch (state.status) {
            .ready => "The engine returned no command.",
            .unavailable => "Configure runtime.engine to enable suggestions.",
            .timeout => "The engine timed out. Try again.",
            .failed => "The engine could not answer. Try again.",
        },
    };
    var lines: WrappedLines = .{ .text = text, .width = content.w };
    var row: u16 = 0;
    while (row < content.h) : (row += 1) {
        const line = lines.next() orelse break;
        try canvas.text(content.row(row), .{ .text = line, .color = if (state.phase == .failed) colors.red else colors.text });
    }

    return lines.next() != null;
}

fn footer(panel: SuggestionPanel, canvas: *Canvas, area: core.Rect) !void {
    const state = panel.projection.suggestion;
    const prompt = panel.projection.prompt.?;
    const bounds = canvas.rect(area);
    const button_width = @min(bounds.width, canvas.chrome.px(190));
    const cancel_width = @min(@max(0, bounds.width - button_width - canvas.chrome.px(12)), canvas.chrome.px(110));
    try (FormButton{ .bounds = .{ .x = bounds.x, .y = bounds.y, .width = cancel_width, .height = bounds.height }, .text = "Close  Esc", .action = .{ .prompt = .cancel }, .generation = prompt.generation, .namespace = 1, .quiet = true }).draw(canvas);
    try (FormButton{ .bounds = .{ .x = bounds.x + bounds.width - button_width, .y = bounds.y, .width = button_width, .height = bounds.height }, .text = switch (state.phase) {
        .ready => "Paste command  Enter",
        .waiting => "Generating…",
        .idle => "Generate  Enter",
        .failed => "Try again  Enter",
    }, .action = .{ .prompt = .submit }, .generation = prompt.generation, .namespace = 2, .primary = true, .enabled = state.phase != .waiting and (state.phase == .ready or prompt.paletteQuery().len != 0) }).draw(canvas);
}
