const PaneStoreType = @import("../../../pane/PaneStore.zig");
const TrackerType = @import("../../../agent/Tracker.zig");
const ServiceType = @import("../../../plugins/Service.zig");
const Resources = @This();

panes: *PaneStoreType,
agents: *TrackerType,
service: *ServiceType,
