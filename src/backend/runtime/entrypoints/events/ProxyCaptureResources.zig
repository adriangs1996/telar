const PaneStoreType = @import("../../../pane/PaneStore.zig");
const ProxyRuntime = @import("../../resources/ProxyRuntime.zig");
const Resources = @This();

panes: *PaneStoreType,
proxy_runtime: *ProxyRuntime,
