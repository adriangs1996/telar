//! Terminal cells and the buffers they fill: styles, geometry, grapheme
//! clusters measured by the `unicode` library, text layout into cells, and
//! the damage rows and run diffing that keep redraws to what changed, and
//! selecting text off a buffer by character, word or line.

const row_sync = @import("row_sync.zig");

pub const Buffer = @import("Buffer.zig");
pub const Cell = @import("Cell.zig");
pub const CellSpan = @import("CellSpan.zig");
pub const ClickTracker = @import("ClickTracker.zig");
pub const Color = @import("Color.zig").Color;
pub const DamageRow = @import("DamageRow.zig");
pub const GraphemeIterator = @import("GraphemeIterator.zig");
pub const Point = @import("Point.zig");
pub const Rect = @import("Rect.zig");
pub const SelectionRange = @import("SelectionRange.zig");
pub const Style = @import("Style.zig");
pub const cell_support = @import("cell_support.zig");
pub const damage = @import("damage.zig");
pub const selection = @import("selection.zig");
pub const syncRow = row_sync.syncRow;
pub const text = @import("text.zig");
