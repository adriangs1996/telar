const client = @import("telar-client");
const Modal = @import("Modal.zig");

const Canvas = @import("../chrome/Canvas.zig");
const PickerModal = @This();

area: @import("telar-core").Rect,
projection: *const client.Projection,

/// Uses the client's canonical fuzzy matches, including its selection ordering.
/// Example: `try widget.draw(canvas);`
pub fn draw(widget: PickerModal, canvas: *Canvas) !void {
    const modal: Modal = .{ .canvas = canvas, .area = widget.area };
    const projection = widget.projection.*;
    const prompt = projection.prompt.?;
    const palette = modal.canvas.theme.palette;
    const sources: client.Sources = .{ .agents = projection.agents, .workspaces = projection.workspaces, .tabs = projection.tabs };
    var results: client.Results = .{};
    client.collect(sources, prompt.field.text(), &results);
    try modal.frame("Go to workspace, tab or agent");

    const content = modal.content();
    try modal.field(content.row(0), prompt);

    const rows = content.splitTop(@min(content.h, 2))[1].splitBottom(1)[0];
    const selected: u16 = if (results.len == 0) 0 else @min(prompt.selection(), results.len - 1);
    const count = @min(rows.h, results.len);
    const start = (selected + 1) -| count;

    for (0..count) |offset| {
        const index = start + offset;
        const row = rows.row(@intCast(offset));
        if (index == selected) {
            try modal.canvas.fill(row, palette.surface1);
        }

        var storage: [client.max_label_bytes]u8 = undefined;
        const label = client.describe(sources, results.slice()[index].item, &storage);
        try modal.canvas.text(row, .{ .text = label, .color = if (index == selected) palette.accent else palette.text, .bold = index == selected });
    }

    if (results.len == 0) {
        try modal.canvas.text(rows.row(0), .{ .text = "No matches", .color = palette.subtext0 });
    }

    if (content.h > 2) {
        try modal.line(content.h - 1, .{ .text = "Up/Down select  Enter open  Esc cancel", .color = palette.subtext0 });
    }
}
