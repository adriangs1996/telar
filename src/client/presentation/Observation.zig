const Observation = @This();
const client_model = @import("../model/root.zig");
const PresentationIngress = @import("PresentationIngress.zig");
model: client_model.Version = .{},
graphics_ingress: u64 = 0,
attachment_ingress: u64 = 0,
geometry_revision: u64 = 0,
presentation_ingress: PresentationIngress = .{},
