const cellgrid = @import("cellgrid");
const core = @import("telar-core");

pane_id: core.PaneId,
content: cellgrid.Rect,
protocol: core.Mouse,
alternate_scroll: bool,
at_bottom: bool,
