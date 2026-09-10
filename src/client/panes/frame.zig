//! Applies validated protocol spans to client-owned cells, without a renderer.

const std = @import("std");
const core = @import("telar-core");
const schema = core.schema;

pub const Applied = struct {
    spans: u64 = 0,
    cells: u64 = 0,
};

/// Applies a frame validated by schema.decodeServer. Pane owns base-frame
/// admission; this function owns only cell replacement and snapshot resizing.
/// Example: const work = try applyBuffer(&buffer, &cursor, frame);
pub fn applyBuffer(buffer: *core.ui.Buffer, cursor: *schema.frame.Cursor, frame: schema.frame.FrameView) !Applied {
    if (frame.base_frame_id == 0 and (buffer.w != frame.cols or buffer.h != frame.rows)) {
        try buffer.resize(frame.cols, frame.rows);
    } else if (buffer.w != frame.cols or buffer.h != frame.rows) {
        return error.PatchSizeMismatch;
    }

    var applied: Applied = .{};
    var spans = frame.spans();
    while (try spans.next()) |span| {
        const start: usize = span.start;
        const count: usize = span.cell_count;
        const end = std.math.add(usize, start, count) catch return error.PatchOutOfBounds;
        if (count == 0 or end > buffer.cells.len) {
            return error.PatchOutOfBounds;
        }

        var cells = span.cells();
        var index = start;
        while (try cells.next()) |cell| : (index += 1) {
            buffer.cells[index] = cell;
            applied.cells += 1;
        }

        std.debug.assert(index == end);
        applied.spans += 1;
    }

    cursor.* = frame.cursor;
    return applied;
}
