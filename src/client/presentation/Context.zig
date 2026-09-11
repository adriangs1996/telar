const PresentationIngress = @import("PresentationIngress.zig");
const hints_support = @import("../input/hints_support.zig");
const RegionType = @import("../workspace/Region.zig");
const Context = @This();

presentation_ingress: PresentationIngress = .{},
status_mode: hints_support.Mode = .normal,
geometry: RegionType,
