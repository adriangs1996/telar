const data = @import("model");
const PresentationIngress = @import("PresentationIngress.zig");
const Observation = @This();

model: data.Version = .{},
graphics_ingress: u64 = 0,
attachment_ingress: u64 = 0,
geometry_revision: u64 = 0,
presentation_ingress: PresentationIngress = .{},
