//! A ghostty-vt terminal seen as cells: its render state projected onto a
//! `cellgrid` buffer with selection highlighting, the changed cells of
//! damaged rows collected into cost-aware spans, and an incremental search
//! of its scrollback.

const blit_module = @import("blit.zig");
const damage = @import("damage.zig");

pub const Diff = @import("Diff.zig");
pub const Counting = @import("Counting.zig").Counting;
pub const GenericSearch = @import("GenericSearch.zig").Type;
pub const SearchLimits = @import("SearchLimits.zig");
pub const blit = blit_module.blit;
pub const collectSpans = damage.collectSpans;
pub const selectionText = blit_module.selectionText;
