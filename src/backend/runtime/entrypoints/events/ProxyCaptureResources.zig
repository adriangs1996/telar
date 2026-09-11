const Resources = @This();
const pane_mod = @import("../../../pane/root.zig");
const proxy_resource = @import("../../resources/proxy.zig");
panes: *pane_mod.PaneStore,
proxy_runtime: *proxy_resource.Runtime,
