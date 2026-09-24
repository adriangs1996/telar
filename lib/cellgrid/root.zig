//! Terminal cells and the buffers they fill: styles, geometry, grapheme
//! clusters measured by the `unicode` library, text layout into cells, and
//! the damage rows and run diffing that keep redraws to what changed.

const row_sync = @import("row_sync.zig");

pub const Buffer = @import("Buffer.zig");
pub const Cell = @import("Cell.zig");
pub const CellSpan = @import("CellSpan.zig");
pub const Color = @import("Color.zig").Color;
pub const DamageRow = @import("DamageRow.zig");
pub const GraphemeIterator = @import("GraphemeIterator.zig");
pub const Point = @import("Point.zig");
pub const Rect = @import("Rect.zig");
pub const Style = @import("Style.zig");
pub const cell_support = @import("cell_support.zig");
pub const damage = @import("damage.zig");
pub const syncRow = row_sync.syncRow;
pub const text = @import("text.zig");

test {
    _ = @import("Box.zig");
    _ = @import("Buffer.zig");
    _ = @import("Cell.zig");
    _ = @import("CellSpan.zig");
    _ = @import("CellWrite.zig");
    _ = @import("Cluster.zig");
    _ = @import("Color.zig");
    _ = @import("DamageRow.zig");
    _ = @import("Fill.zig");
    _ = @import("Flags.zig");
    _ = @import("GraphemeIterator.zig");
    _ = @import("Point.zig");
    _ = @import("Rect.zig");
    _ = @import("RightAlignedText.zig");
    _ = @import("Style.zig");
    _ = @import("TextWrite.zig");
    _ = @import("TruncatedText.zig");
    _ = @import("buffer_support.zig");
    _ = @import("cell_support.zig");
    _ = @import("damage.zig");
    _ = @import("geometry.zig");
    _ = @import("row_sync.zig");
    _ = @import("text.zig");
    _ = @import("ui_tests.zig");
}
