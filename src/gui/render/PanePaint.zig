const client = @import("telar-client");
const data = @import("model");
pane: *const client.Pane,
view: data.LayoutView,
copy: ?data.CopyModeView = null,
hide_cursor: bool = false,
