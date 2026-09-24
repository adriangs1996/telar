//! Terminal cells and the buffers they fill: styles, geometry, grapheme
//! clusters measured by the `unicode` library, and text layout into cells.

pub const Buffer = @import("Buffer.zig");
pub const Cell = @import("Cell.zig");
pub const GraphemeIterator = @import("GraphemeIterator.zig");
pub const Point = @import("Point.zig");
pub const Rect = @import("Rect.zig");
pub const Style = @import("Style.zig");
pub const cell_support = @import("cell_support.zig");
pub const text = @import("text.zig");

test {
    _ = @import("Box.zig");
    _ = @import("Buffer.zig");
    _ = @import("Cell.zig");
    _ = @import("CellWrite.zig");
    _ = @import("Cluster.zig");
    _ = @import("Color.zig");
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
    _ = @import("geometry.zig");
    _ = @import("text.zig");
    _ = @import("ui_tests.zig");
}
