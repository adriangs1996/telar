const Resources = @This();
const client_view = @import("view.zig");
const source_namespace = @import("Presenter.zig");
view: *client_view.State,
graphics_store: *source_namespace.kitty.Store,
writer: *source_namespace.Io.Writer,
