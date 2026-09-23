const lifecycle = @import("lifecycle.zig");
const Observation = @import("Observation.zig");
const Geometry = @import("Geometry.zig");
const PresentationDelivery = @import("PresentationDelivery.zig");
const Flight = @This();

token: lifecycle.Token,
observation: Observation,
geometry: Geometry,
delivery: PresentationDelivery,
