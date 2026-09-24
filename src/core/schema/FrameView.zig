const id = @import("id.zig");
const Cursor = @import("Cursor.zig");
const Mouse = @import("Mouse.zig");
const InputModes = @import("InputModes.zig");
const frame_support = @import("frame_support.zig");
const Scroll = @import("Scroll.zig");
const Decoder = @import("Decoder.zig");
const cellgrid = @import("cellgrid");
const Style = cellgrid.Style;
const Cell = cellgrid.Cell;
const View = @import("../text_metadata/View.zig");
const FrameView = @This();

pane_id: id.PaneId,
frame_id: u64,
base_frame_id: u64,
cols: u16,
rows: u16,
cursor: Cursor,
mouse: Mouse,
input_modes: InputModes,
pointer_shape: frame_support.PointerShape = .default,
/// Null preserves patch metadata; encoding a snapshot with null emits an empty replacement.
text_metadata: ?View = null,
scroll: Scroll,
span_count: u16,
encoded_spans: []const u8,

pub fn isSnapshot(self: FrameView) bool {
    return self.base_frame_id == 0;
}

pub fn spans(self: FrameView) SpanIterator {
    return .{
        .decoder = .init(self.encoded_spans),
        .remaining = self.span_count,
    };
}

const SpanIterator = struct {
    decoder: Decoder,
    remaining: u16,

    pub fn next(self: *SpanIterator) error{Truncated}!?SpanView {
        if (self.remaining == 0) {
            return null;
        }
        self.remaining -= 1;

        const start = try self.decoder.readInt(u32);
        const count = try self.decoder.readInt(u32);
        const encoded_length = try self.decoder.readInt(u32);
        const encoded_cells = try self.decoder.readBytes(encoded_length);
        return .{
            .start = start,
            .cell_count = count,
            .encoded_cells = encoded_cells,
        };
    }

    const SpanView = struct {
        start: u32,
        cell_count: u32,
        encoded_cells: []const u8,

        pub fn cells(self: SpanView) CellIterator {
            return .{
                .decoder = .init(self.encoded_cells),
                .remaining = self.cell_count,
            };
        }
    };
};

const CellIterator = struct {
    decoder: Decoder,
    remaining: u32,
    style: ?Style = null,

    pub fn next(self: *CellIterator) !?Cell {
        if (self.remaining == 0) {
            return null;
        }
        self.remaining -= 1;
        const cell = try frame_support.decodeCell(&self.decoder, &self.style);
        // The span header promised exactly `cell_count` cells; leftover bytes
        // after the last one are corruption, not padding.
        if (self.remaining == 0) {
            try self.decoder.ensureEnd();
        }
        return cell;
    }
};
