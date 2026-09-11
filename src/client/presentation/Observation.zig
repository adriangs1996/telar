const VersionType = @import("../model/Version.zig");
const PresentationIngress = @import("PresentationIngress.zig");
const Observation = @This();

model: VersionType = .{},
graphics_ingress: u64 = 0,
attachment_ingress: u64 = 0,
geometry_revision: u64 = 0,
presentation_ingress: PresentationIngress = .{},
