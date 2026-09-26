//! What the terminal panel draws from: the screen, the bar row it rises
//! from, the bar state and the facts built-in components read.
const cellgrid = @import("cellgrid");
const data = @import("model");
const BarPanelInput = @This();

/// The whole terminal.
application: cellgrid.Rect,
/// The bottom bar row the panel rises from.
bottom: cellgrid.Rect,
bar_state: *const data.BarsState,
facts: *const data.BarFacts,
/// The components the bar slots hid in this frame.
overflow: ?*const data.BarOverflow = null,
